import Foundation
import CryptoKit

func kbLog(_ message: String) { print("log: \(message)") }
enum AutocompletePrefs { static var idleUnloadMinutes = 60 }
struct Case {
    let id: String
    let before: String
    let app: String
    let target: String
    let records: [(String, String)]
}
let cases: [Case] = [
    Case(id: "ru-chat-term", before: "Кэш проекта называется", app: "chat", target: "РекаКэш", records: [
        ("Напоминание команде: кэш проекта называется РекаКэш для всех сессий.", "chat"),
        ("Сегодня подтвердили: кэш проекта называется РекаКэш после миграции.", "chat"),
        ("В письме договорились: кэш проекта называется ПамятьПочты для всех сессий.", "mail"),
        ("Уточнение письма: кэш проекта называется ПамятьПочты после миграции.", "mail")]),
    Case(id: "ru-mail-term", before: "Кэш проекта называется", app: "mail", target: "ПамятьПочты", records: [
        ("В письме договорились: кэш проекта называется ПамятьПочты для всех сессий.", "mail"),
        ("Уточнение письма: кэш проекта называется ПамятьПочты после миграции.", "mail"),
        ("Напоминание команде: кэш проекта называется РекаКэш для всех сессий.", "chat"),
        ("Сегодня подтвердили: кэш проекта называется РекаКэш после миграции.", "chat")]),
    Case(id: "en-chat-term", before: "Our deployment target is", app: "chat", target: "CedarBridge", records: [
        ("Yesterday we agreed: our deployment target is CedarBridge for this release.", "chat"),
        ("The team confirmed: our deployment target is CedarBridge after migration.", "chat"),
        ("The email explains: our deployment target is HarborNotes for this release.", "mail"),
        ("A mail follow-up: our deployment target is HarborNotes after migration.", "mail")]),
    Case(id: "en-mail-term", before: "Our deployment target is", app: "mail", target: "HarborNotes", records: [
        ("The email explains: our deployment target is HarborNotes for this release.", "mail"),
        ("A mail follow-up: our deployment target is HarborNotes after migration.", "mail"),
        ("Yesterday we agreed: our deployment target is CedarBridge for this release.", "chat"),
        ("The team confirmed: our deployment target is CedarBridge after migration.", "chat")]),
    Case(id: "ru-phrase", before: "Задача готова к пров", app: "chat", target: "ерке коллегой", records: [
        ("С утра задача готова к проверке коллегой завтра.", "chat"),
        ("После правки задача готова к проверке коллегой сегодня.", "chat"),
        ("В отчёте задача готова к проведению демонстрации заказчику.", "mail")]),
    Case(id: "en-phrase", before: "send the report to Riv", app: "chat", target: "erTeam", records: [
        ("Tomorrow please send the report to RiverTeam before lunch.", "chat"),
        ("We agreed to send the report to RiverTeam after review.", "chat"),
        ("The email asks to send the report to OfficeTeam today.", "mail")]),
    Case(id: "ru-name", before: "Релиз проверяет", app: "chat", target: "Мирослава", records: [
        ("Сегодня релиз проверяет Мирослава после обеда.", "chat"),
        ("Завтра релиз проверяет Мирослава с командой.", "chat"),
        ("В другом проекте релиз проверяет Константин после обеда.", "mail")]),
    Case(id: "ru-unicode", before: "Встреча назначена с Сем", app: "mail", target: "ёном", records: [
        ("Подтверждаю: встреча назначена с Семёном на пятницу.", "mail"),
        ("Напоминаю: встреча назначена с Семёном после обеда.", "mail")]),
    Case(id: "fresh-ru-chat-date", before: "Согласуем встречу", app: "chat", target: "в четверг", records: [
        ("Вчера договорились: согласуем встречу в четверг после обеда.", "chat"),
        ("Сегодня решили: согласуем встречу в четверг с командой.", "chat"),
        ("В переписке: согласуем встречу во вторник после обеда.", "mail"),
        ("Уточняю письмо: согласуем встречу во вторник утром.", "mail")]),
    Case(id: "fresh-en-chat-branch", before: "The release branch is", app: "chat", target: "willow", records: [
        ("The team agreed: the release branch is willow after review.", "chat"),
        ("Yesterday we confirmed: the release branch is willow for this sprint.", "chat"),
        ("The email states: the release branch is maple after review.", "mail"),
        ("A follow-up says the release branch is maple for this sprint.", "mail")]),
    Case(id: "fresh-ru-mail-name", before: "Отчёт отправим", app: "mail", target: "Антону", records: [
        ("Договорились в письме: отчёт отправим Антону после обеда.", "mail"),
        ("Подтверждаю: отчёт отправим Антону сегодня вечером.", "mail"),
        ("В чате договорились: отчёт отправим Вадиму после обеда.", "chat"),
        ("Напоминаю команде: отчёт отправим Вадиму сегодня вечером.", "chat")]),
    Case(id: "fresh-en-mail-date", before: "Please schedule the call for", app: "mail", target: "Thursday", records: [
        ("I wrote: please schedule the call for Thursday after lunch.", "mail"),
        ("A follow-up: please schedule the call for Thursday with the team.", "mail"),
        ("In chat: please schedule the call for Monday after lunch.", "chat"),
        ("The chat reminder: please schedule the call for Monday with the team.", "chat")]),
    Case(id: "unrelated-ru", before: "Обсудим бюджет будущего квартала", app: "chat", target: "", records: [
        ("Кэш проекта называется РекаКэш после миграции.", "chat"),
        ("Сегодня команда снова проверяет РекаКэш для сессий.", "chat")]),
    Case(id: "unrelated-en", before: "The weather forecast for tomorrow", app: "mail", target: "", records: [
        ("Our deployment target is CedarBridge for this release.", "mail"),
        ("Yesterday the team confirmed CedarBridge after migration.", "mail")])
]
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPEAKEY_WRITING_EVAL_DIR"]!)
let key = SymmetricKey(data: Data(repeating: 31, count: 32))
let model = CompletionModels.all.first { $0.id == CompletionModels.defaultID && CompletionModels.isInstalled($0) }!
let engine = CompletionEngine.shared
engine.ensureRunning(model: CompletionModels.localURL(model))
let deadline = Date().addingTimeInterval(60)
while engine.state != .ready && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
guard engine.state == .ready else { engine.stop(); exit(1) }
var results: [[String: Any]] = []
for fixture in cases {
    let directory = root.appendingPathComponent(fixture.id)
    let old = BaselinePersonalCorpus(directory: directory.appendingPathComponent("old"), keyProvider: { key })
    let current = PersonalCorpus(directory: directory.appendingPathComponent("new"), keyProvider: { key })
    for (text, app) in fixture.records { old.add(text, bundleID: app); current.add(text, bundleID: app) }
    var baseline = CompletionContext(appName: fixture.app, before: fixture.before)
    baseline.snippets = old.similar(to: fixture.before, limit: 3)
    baseline.terms = old.topTerms(limit: 20)
    var improved = CompletionContext(appName: fixture.app, before: fixture.before)
    let profile = current.personalization(before: fixture.before, bundleID: fixture.app, strength: 2)
    improved.snippets = profile.snippets; improved.terms = profile.terms
    for (arm, context) in [("before", baseline), ("after", improved)] {
        let prompt = CompletionPrompt.build(context)
        var reply: String?, done = false
        let start = Date()
        engine.complete(prompt: prompt, maxTokens: 20, temperature: CompletionPrompt.continuationTemperature, seed: 42) {
            reply = $0; done = true
        }
        while !done && Date().timeIntervalSince(start) < 12 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let text = CompletionPrompt.cleanContinuation(reply ?? "", before: fixture.before, context: context, maxWords: 6)
        let names = ["РекаКэш", "ПамятьПочты", "CedarBridge", "HarborNotes"]
        let row: [String: Any] = ["id": fixture.id, "arm": arm, "target": fixture.target, "text": text,
            "target_present": !fixture.target.isEmpty && text.localizedCaseInsensitiveContains(fixture.target),
            "unexpected_term": fixture.target.isEmpty && names.contains { text.localizedCaseInsensitiveContains($0) },
            "completed": done && reply != nil, "elapsed_ms": Int(Date().timeIntervalSince(start) * 1000),
            "prompt_chars": prompt.count, "snippets": context.snippets,
            "has_continuation": arm == "after" && profile.continuation != nil]
        results.append(row)
        print("\(fixture.id) \(arm): \(text)")
    }
}
engine.stop()
let output: [String: Any] = ["model": model.id, "temperature": 0, "max_tokens": 20, "cases": cases.count, "results": results]
try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
exit(results.allSatisfy { $0["completed"] as? Bool == true } ? 0 : 1)
