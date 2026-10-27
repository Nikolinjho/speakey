import Foundation
import CoreGraphics
import Darwin

// Локальные CGEvent не публикуются. Измеряется только production Runtime.observe.
func kbLog(_ message: String) {}
func clockNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func percentiles(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    func q(_ p: Double) -> Double { sorted[Int(ceil(p * Double(sorted.count))) - 1] }
    return ["p50": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": sorted.last!]
}
do {
    let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let sha = "5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704"
    let profile = try NeuralLayoutProfile(modelSHA256: sha, enabled: false, minimumScore: 0.99, minimumMargin: 0.5)
    for mode in NeuralLayoutMode.allCases {
        let presentation = NeuralLayoutPresentationStore()
        let runtime = NeuralLayoutRuntime(mode: mode, presentation: presentation, factory: {
            NeuralLayoutLoadedBackend(backend: try RightLayoutModel(modelURL: modelURL), modelID: "rightlayout-ensemble-20-v1", sha256: sha, profile: profile)
        })
        let deadline = Date(timeIntervalSinceNow: 10)
        while runtime.status == .loading && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        precondition(mode == .off || runtime.status == .ready)
        var spans: [Double] = [], ages: [Double] = []
        for _ in 0..<1000 {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            func eventClock() -> UInt64 {
                UInt64(Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom))
            }
            event.timestamp = eventClock()
            let start = clockNs()
            let ageEnd = eventClock()
            ages.append(Double(ageEnd - event.timestamp) / 1_000_000)
            runtime.changed()
            runtime.observe(occurrenceID: UUID(), word: "ghbdtn", bundleID: "test.isolated.input", layoutCode: "en", collecting: false)
            spans.append(Double(clockNs() - start) / 1_000_000)
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        let value: [String: Any] = ["kind": "syntheticRuntimeInput", "mode": mode.rawValue,
            "effectiveMode": presentation.value.effectiveMode.rawValue, "samples": 1000,
            "scope": "local unposted CGEvent with explicit mach-absolute nanosecond stamp; Runtime.changed+observe span; excludes EventTap.handle and OS transport",
            "submissionSpanMs": percentiles(spans), "localEventAgeMs": percentiles(ages)]
        print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
        runtime.stop()
    }
} catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
