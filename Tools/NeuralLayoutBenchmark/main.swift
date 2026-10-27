import Foundation
import CoreML
import CryptoKit
import Darwin
import ApplicationServices

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func elapsed(_ start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
func rss() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return info.resident_size
}
func summary(_ samples: [Double]) -> [String: Double] {
    let sorted = samples.sorted()
    func q(_ p: Double) -> Double { sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)] }
    return ["p50": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": sorted.last!]
}
func emit(_ data: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
    print(String(decoding: bytes, as: UTF8.self))
    fflush(stdout)
}
final class MeasuredBackend: NeuralLayoutBackend {
    let underlying: NeuralLayoutBackend?
    private let lock = NSLock()
    private var active = 0
    private(set) var maximum = 0
    init(_ backend: NeuralLayoutBackend?) { underlying = backend }
    func predict(_ word: String) throws -> NeuralLayoutScores {
        lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if let underlying { return try underlying.predict(word) }
        return try NeuralLayoutScores(logits: Array(repeating: 0, count: 9))
    }
    func peak() -> Int { lock.lock(); defer { lock.unlock() }; return maximum }
}
#if arch(arm64)
let architecture = "arm64"
#elseif arch(x86_64)
let architecture = "x86_64"
#else
let architecture = "unknown"
#endif
func cpuModel() -> String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 else { return "unavailable" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
    return String(cString: bytes)
}
func stress(_ backend: NeuralLayoutBackend?, name: String) throws {
    let measured = MeasuredBackend(backend)
    var callbacks = 0, errors = 0, activePeak = 0, pendingPeak = 0
    var accepting = true, lateCallbacks = 0
    let coordinator = NeuralLayoutCoordinator(backend: measured) { result in
        callbacks += 1
        if !accepting { lateCallbacks += 1 }
        if case .failure = result { errors += 1 }
    }
    let epoch = UUID(), occurrence = UUID(), start = now()
    let seconds = CommandLine.arguments.contains("--smoke") ? 1 : 300
    let submissions = seconds * 100
    let rssBefore = rss()
    var rssPeak = rssBefore
    // Накопившиеся тики не выбрасываются: все 30 000 отправок имеют фиксированные deadlines.
    for index in 0..<submissions {
        let deadline = start + UInt64(index) * 10_000_000
        while true {
            let tick = now()
            guard tick < deadline else { break }
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: min(0.001, Double(deadline - tick) / 1e9)))
        }
        coordinator.submit(NeuralLayoutRequest(epoch: epoch, revision: UInt64(index), occurrenceID: occurrence,
            bundleID: "test.isolated.benchmark", layoutCode: "en", word: "ghbdtn"))
        activePeak = max(activePeak, coordinator.activeRequestCount)
        pendingPeak = max(pendingPeak, coordinator.pendingRequestCount)
        if index % 100 == 0 { rssPeak = max(rssPeak, rss()) }
    }
    // Последний интервал включён в пяти­минутное окно.
    while elapsed(start) < Double(seconds * 1000) { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001)) }
    let duration = elapsed(start)
    // Создаём незавершённую работу непосредственно перед stop/invalidate.
    coordinator.submit(NeuralLayoutRequest(epoch: epoch, revision: UInt64(submissions), occurrenceID: occurrence,
        bundleID: "test.isolated.benchmark", layoutCode: "en", word: "hello"))
    coordinator.invalidate(); accepting = false
    let stopStart = now()
    while coordinator.activeRequestCount > 0 && elapsed(stopStart) < 10_000 {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }
    precondition(activePeak <= 1 && pendingPeak <= 1 && measured.peak() <= 1)
    precondition(coordinator.activeRequestCount == 0 && coordinator.pendingRequestCount == 0 && lateCallbacks == 0 && errors == 0)
    try emit(["kind": "stress", "backend": name, "durationMs": duration, "ratePerSecond": 100,
        "submissions": submissions, "stopProbeSubmissions": 1, "callbacks": callbacks, "errors": errors,
        "activePeak": activePeak, "pendingPeak": pendingPeak, "workerConcurrencyPeak": measured.peak(),
        "callbacksAfterInvalidation": lateCallbacks, "rssBeforeBytes": rssBefore, "rssPeakSampledBytes": rssPeak, "rssAfterBytes": rss()])
}

do {
    let arguments = CommandLine.arguments
    let raw = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let sha = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    precondition(sha == "5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704")
    let before = rss(), coldStart = now()
    let model = try RightLayoutModel(modelURL: URL(fileURLWithPath: arguments[1]))
    let load = elapsed(coldStart), firstStart = now()
    _ = try model.predict("ghbdtn")
    let first = elapsed(firstStart)
    let words = ["ghbdtn", "hello", "привет", "руддщ", "world", "экскурсия"]
    for index in 0..<50 { _ = try model.predict(words[index % words.count]) }
    let warmRSS = rss()
    var samples: [Double] = []
    for index in 0..<1000 {
        let start = now(); _ = try model.predict(words[index % words.count]); samples.append(elapsed(start))
    }
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let stats = summary(samples)
    try emit(["kind": "prediction", "modelSHA256": sha, "computeUnits": "cpuOnly",
        "os": ProcessInfo.processInfo.operatingSystemVersionString, "arch": architecture, "cpuModel": cpuModel(), "modelID": "rightlayout-ensemble-20-v1", "warmups": 50,
        "samples": samples.count, "quantile": "ceil(p*n)-1", "loadMs": load, "firstPredictionMs": first,
        "loadAndFirstMs": load + first, "coldScope": "first model instance in process; filesystem cache uncontrolled",
        "predictionMs": stats, "rssBeforeModelBytes": before, "rssAfterWarmupBytes": warmRSS,
        "processMaxRSSBytes": usage.ru_maxrss, "cpuP95Pass": stats["p95"]! <= 5,
        "accessibilityTrusted": AXIsProcessTrusted(), "inputMonitoringAllowed": CGPreflightListenEventAccess()])
    try stress(nil, name: "dummy")
    try stress(model, name: "RightLayoutModel.cpuOnly")
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
