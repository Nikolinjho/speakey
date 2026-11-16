import Foundation
import CryptoKit

func kbLog(_ message: String) {}
enum CompletionText { static func redactSecrets(_ text: String) -> String { text } }
var checks = 0, failures = 0
func check(_ name: String, _ value: Bool) {
    checks += 1
    if !value { failures += 1 }
    print("\(value ? "PASS" : "FAIL"): \(name)")
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("speakey-writing-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: directory) }
let key = SymmetricKey(data: Data(repeating: 23, count: 32))
let corpus = PersonalCorpus(directory: directory, keyProvider: { key })
corpus.add("Сегодня обсуждали Speakey с командой каталога.", bundleID: "chat")
corpus.add("Вчера исправили Speakey после проверки коллегой.", bundleID: "chat")
corpus.add("Встреча с Никитой состоится завтра после обеда.", bundleID: "mail")
corpus.add("Подтверждаю разговор с Никитой на следующей неделе.", bundleID: "mail")
check("Личный словарь сохраняет написание Speakey", corpus.topTerms(limit: 20).contains("Speakey"))
check("Личный словарь сохраняет написание имени", corpus.topTerms(limit: 20).contains("Никитой"))
check("Удаление убирает слова источника", corpus.remove(bundleID: "mail") && !corpus.topTerms(limit: 20).contains("Никитой"))

func sample(_ text: String, _ app: String = "chat", _ date: Double = 100) -> PersonalCorpus.Record {
    PersonalCorpus.Record(text: text, bundleID: app, date: date)
}
let records = [
    sample("Напоминание: отправим задачу на проверку коллегой завтра", "chat", 200),
    sample("Договорились: отправим задачу на проверку коллегой завтра", "chat", 100),
    sample("В письме: отправим задачу на согласование руководителю", "mail", 300),
    sample("Today we send reports to RiverCache after lunch", "mail", 400),
    sample("Yesterday we send reports to RiverCache after lunch", "mail", 500)
]
let index = PersonalWritingIndex(records: records)
let ru = index.continuation(after: "Окей, отправим задачу на ПРОВ", bundleID: "chat", maxWords: 3)
check("Русский префикс совпадает независимо от регистра", ru?.text == "ерку коллегой завтра")
check("Поддержка русской фразы равна двум записям", ru?.support == 2)
check("Пример содержит законченное слово вместо фрагмента", ru?.example == "отправим задачу на проверку коллегой завтра")
let en = index.continuation(after: "we send reports to Riv", bundleID: "mail", maxWords: 3)
check("Английский префикс сохраняет регистр продолжения", en?.text == "erCache after lunch")
check("Пробел после слова открывает следующее слово", index.continuation(after: "отправим задачу на ", bundleID: "chat", maxWords: 1)?.text == " проверку")
check("Короткое совпадение не становится личной подсказкой", index.continuation(after: "на пр", bundleID: "chat") == nil)
check("Одна буква не запускает поиск личного продолжения", index.continuation(after: "отправим задачу на п", bundleID: "chat") == nil)
check("После конца предложения продолжение не подставляется", index.continuation(after: "отправим задачу на.", bundleID: "chat") == nil)
check("Нулевой лимит слов отключает продолжение", index.continuation(after: "отправим задачу на ", maxWords: 0) == nil)
check("Нулевой уровень исключает весь личный контекст", index.profile(before: "отправим задачу", bundleID: "chat", strength: 0).snippets.isEmpty && index.profile(before: "отправим задачу", bundleID: "chat", strength: 0).terms.isEmpty)
check("Средний уровень ставит привычное продолжение первым", index.profile(before: "отправим задачу на пров", bundleID: "chat", strength: 2).snippets.first == ru?.example)
check("Слабый уровень требует трёх подтверждений привычки", index.profile(before: "отправим задачу на пров", bundleID: "chat", strength: 1).continuation == nil)
check("Лимит примеров слабого уровня сохраняется", index.profile(before: "отправим задачу", bundleID: "chat", strength: 1).snippets.count <= 1)
check("Посторонний текст не подбирает примеры", index.examples(before: "Крокодилы изучают астрономию", limit: 5).isEmpty)
let apps = PersonalWritingIndex(records: [
    sample("Обсудим проект Speakey после встречи завтра", "chat", 1),
    sample("Обсудим проект Speakey после встречи сегодня", "mail", 200)
])
check("Текущее приложение важнее свежести при одинаковой теме", apps.examples(before: "Обсудим проект Speakey", bundleID: "chat", limit: 1).first?.contains("завтра") == true)
let languages = PersonalWritingIndex(records: [
    sample("Сегодня наша команда подробно обсуждает RiverCache перед выпуском", "chat", 1),
    sample("Today the team carefully discusses RiverCache before release", "chat", 200)
])
check("Язык запроса влияет на выбор примера", languages.examples(before: "Коллеги, поговорим о RiverCache", bundleID: "chat", limit: 1).first?.hasPrefix("Сегодня") == true)
let one = PersonalWritingIndex(records: [sample("отправим задачу на проверку коллегой завтра. отправим задачу на проверку коллегой завтра")])
check("Повтор внутри одного документа не считается двумя подтверждениями", one.continuation(after: "отправим задачу на пров") == nil)
let boundaries = PersonalWritingIndex(records: [sample("Мы согласовали итоговый план"), sample("проверки коллегой завтра утром")])
check("Продолжение не склеивает разные документы", boundaries.continuation(after: "Мы согласовали итоговый план", minimumSupport: 1) == nil)
let sentences = PersonalWritingIndex(records: [sample("Начало: проверка готова. Обсудим план завтра утром")])
check("Совпадение не перескакивает через конец предложения", sentences.continuation(after: "проверка готова обсу", minimumSupport: 1) == nil)
let unicode = PersonalWritingIndex(records: [sample("Пожалуйста, обсудим план с Семёном сегодня вечером")])
check("Составная ё совпадает с канонической формой", unicode.continuation(after: "обсудим план с семе\u{0308}", maxWords: 1, minimumSupport: 1)?.text == "ном")
let stop = PersonalWritingIndex(records: [sample("Напоминаю: проверим новый сценарий сегодня. Потом займёмся другим проектом")])
check("Личная фраза заканчивается вместе с предложением", stop.continuation(after: "проверим новый сценарий ", maxWords: 5, minimumSupport: 1)?.text == " сегодня")
let live = PersonalCorpus(directory: directory.appendingPathComponent("live"), keyProvider: { key })
for r in records { live.add(r.text, bundleID: r.bundleID) }
check("Производственный профиль находит личную фразу", live.personalization(before: "отправим задачу на пров", bundleID: "chat", strength: 2).continuation != nil)
check("Перечитывание корпуса восстанавливает индекс", PersonalCorpus(directory: directory.appendingPathComponent("live"), keyProvider: { key }).personalization(before: "отправим задачу на пров", bundleID: "chat", strength: 2).continuation != nil)
let id = live.snapshot().records.first { $0.text.hasPrefix("Напоминание") }!.id
check("Удаление одной записи сразу снимает подтверждённую привычку", live.remove(id: id) && live.personalization(before: "отправим задачу на пров", bundleID: "chat", strength: 2).continuation == nil)
check("Удаление приложения очищает его примеры", live.remove(bundleID: "chat") && !live.personalization(before: "отправим задачу", bundleID: "chat", strength: 2).snippets.contains { $0.contains("проверку коллегой") })
check("Полная очистка сразу очищает профиль", live.removeAll() && live.personalization(before: "we send reports", bundleID: "mail", strength: 3).snippets.isEmpty)
var rejectWrites = false
let failing = PersonalCorpus(directory: directory.appendingPathComponent("fail"), keyProvider: { key }, writer: { data, url in
    if rejectWrites { throw CocoaError(.fileWriteNoPermission) }
    try data.write(to: url, options: .atomic)
})
for r in records.prefix(2) { failing.add(r.text, bundleID: "chat") }
_ = failing.personalization(before: "отправим задачу на пров", bundleID: "chat", strength: 2)
rejectWrites = true
check("Ошибка удаления сохраняет прежний профиль", !failing.removeAll() && failing.personalization(before: "отправим задачу на пров", bundleID: "chat", strength: 2).continuation != nil)
check("Ошибка добавления не попадает в профиль", !failing.add("Совершенно секретный новый проект RiverDelta сегодня", bundleID: "chat") && !failing.personalization(before: "новый проект", bundleID: "chat", strength: 2).snippets.contains { $0.contains("RiverDelta") })
let source = records[0]
let changed = sample(source.text.precomposedStringWithCanonicalMapping, "chat", 999)
let rebuilt = PersonalWritingIndex(records: [changed] + Array(records.dropFirst()), previous: index)
check("Перестройка сохраняет результат поиска", rebuilt.continuation(after: "отправим задачу на пров", bundleID: "chat", maxWords: 3)?.text == ru?.text)
let canonicalRecord = sample("Пожалуйста, обсудим план с Семёном сегодня вечером")
let canonicalIndex = PersonalWritingIndex(records: [canonicalRecord])
var decomposedRecord = canonicalRecord
decomposedRecord.text = canonicalRecord.text.decomposedStringWithCanonicalMapping
let decomposedIndex = PersonalWritingIndex(records: [decomposedRecord], previous: canonicalIndex)
check("Повторная токенизация учитывает изменение Unicode-представления", decomposedIndex.continuation(after: "обсудим план с семё", maxWords: 1, minimumSupport: 1)?.text == "ном")
let varied = PersonalWritingIndex(records: [
    sample("Вчера согласовали: наш кэш называется RiverCache для сессий"),
    sample("Сегодня подтвердили: наш кэш называется RiverCache после миграции")
])
check("Разные окончания не скрывают общее привычное слово", varied.continuation(after: "наш кэш называется ", bundleID: "chat")?.text == " RiverCache")
if CommandLine.arguments.contains("--benchmark") {
    let records = (0..<5000).map { index in
        sample("Сообщение \(index): договорились проверить задачу в Speakey перед релизом завтра утром вместе с командой каталога.", index.isMultiple(of: 2) ? "chat" : "mail", Double(index))
    }
    let started = Date()
    let large = PersonalWritingIndex(records: records)
    let build = Date().timeIntervalSince(started) * 1000
    var updated = records
    updated[0].text += " Подтверждено."
    let updateStart = Date()
    _ = PersonalWritingIndex(records: updated, previous: large)
    print(String(format: "BENCH: incremental rebuild %.1f ms", Date().timeIntervalSince(updateStart) * 1000))
    var timings: [Double] = []
    for _ in 0..<30 {
        let start = Date()
        _ = large.profile(before: "договорились проверить задачу в Speakey ", bundleID: "chat", strength: 2)
        timings.append(Date().timeIntervalSince(start) * 1000)
    }
    timings.sort()
    print(String(format: "BENCH: 5000 records, build %.1f ms, query median %.2f ms, p95 %.2f ms", build, timings[timings.count / 2], timings[Int(Double(timings.count - 1) * 0.95)]))
}
let focused = index.profile(before: "отправим задачу на пров", bundleID: "chat", strength: 2)
check("Подтверждённая привычка приложения не смешивается с чужим вариантом", !focused.snippets.contains { $0.contains("согласование руководителю") })
let support = PersonalWritingIndex(records: [
    sample("please send weekly summary to AlphaTeam tomorrow"),
    sample("always send daily summary to AlphaTeam tomorrow"),
    sample("Yesterday send weekly summary to BetaTeam today"),
    sample("Tomorrow send weekly summary to BetaTeam today")
])
check("Длинное разовое совпадение не заимствует поддержку короткого", support.continuation(after: "please send weekly summary to ", bundleID: "chat")?.text == " BetaTeam today")
for newline in ["\n", "\r\n", "\r"] {
    let lines = PersonalWritingIndex(records: [sample("please send report" + newline + "Tomorrow we meet")])
    check("Продолжение не перескакивает через перенос \(newline.debugDescription)", lines.continuation(after: "please send report ", minimumSupport: 1) == nil)
}
final class BuildGate {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true; return true
    }
}
let buildQueue = DispatchQueue(label: "speakey.test.index-race")
let oldStarted = DispatchSemaphore(value: 0), releaseOld = DispatchSemaphore(value: 0)
let gate = BuildGate()
let racing = PersonalCorpus(directory: directory.appendingPathComponent("race"), keyProvider: { key }, indexQueue: buildQueue, indexBuilder: { records, previous in
    if !records.isEmpty, gate.claim() {
        oldStarted.signal()
        releaseOld.wait()
    }
    return PersonalWritingIndex(records: records, previous: previous)
})
racing.add("Этот старый словарь содержит RiverGate перед удалением", bundleID: "race")
let startedOld = oldStarted.wait(timeout: .now() + 5) == .success
check("Старая сборка управляемо запущена до удаления", startedOld)
check("Удаление не ждёт тяжёлую сборку индекса", racing.removeAll())
check("Запрос во время старой сборки видит очищенный корпус", racing.personalization(before: "старый словарь содержит", bundleID: "race", strength: 2).snippets.isEmpty)
releaseOld.signal()
buildQueue.sync {}
check("Завершившаяся старая сборка не возвращает удалённую историю", racing.personalization(before: "старый словарь содержит", bundleID: "race", strength: 2).snippets.isEmpty)
print("personal writing: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
