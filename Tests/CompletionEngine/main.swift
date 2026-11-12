import Foundation

// Смоук помощника: настоящий llama-server, настоящая модель, без остального Speakey.
func kbLog(_ message: String) { print("log: \(message)") }
enum AutocompletePrefs { static var idleUnloadMinutes = 60 }

let model = CompletionModels.all.first { CompletionModels.isInstalled($0) }
guard let model else { print("engine: нет установленной модели"); exit(1) }
let engine = CompletionEngine.shared
engine.ensureRunning(model: CompletionModels.localURL(model))
let deadline = Date().addingTimeInterval(120)
while engine.state != .ready, Date() < deadline {
    if case .failed(let why) = engine.state { print("engine: FAIL \(why)"); exit(1) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
guard engine.state == .ready else { print("engine: FAIL не поднялся"); exit(1) }

// Отмена: второй запрос до ответа первого — первый получает nil.
var first: String?? = .none
var second: String?? = .none
engine.complete(prompt: "Привет! Давно не виделись, как у тебя", maxTokens: 8) { first = .some($0) }
let t0 = Date()
engine.complete(prompt: "Привет! Давно не виделись, как у тебя", maxTokens: 8) { second = .some($0) }
while second == nil, Date().timeIntervalSince(t0) < 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
let ms = Int(Date().timeIntervalSince(t0) * 1000)
var failed = false
if case .some(.some) = first { print("FAIL: отменённый запрос получил ответ"); failed = true }
guard case .some(.some(let text)) = second, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
    print("FAIL: пустое дополнение"); engine.stop(); exit(1)
}
// Повтор с тёплым кэшем — так выглядит набор.
var times: [Int] = []
for extra in ["", " д", " де", " дел", " дела"] {
    var got = false
    let t = Date()
    engine.complete(prompt: "Привет! Давно не виделись, как у тебя" + extra, maxTokens: 8) { _ in got = true }
    while !got, Date().timeIntervalSince(t) < 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    times.append(Int(Date().timeIntervalSince(t) * 1000))
}
engine.stop()
print("ответ длиной \(text.count) симв.; тёплые запросы, мс: \(times)")
print(failed ? "engine: FAIL" : "engine: ok \(ms)")
exit(failed ? 1 : 0)
