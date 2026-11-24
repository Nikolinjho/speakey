import Foundation
import CryptoKit
import Darwin

func checkCreationOrder(root: URL, key: Data) throws {
    let diagnostics = root.appendingPathComponent("dated-diagnostics")
    let store = SpeechReviewStore(diagnosticsDirectory: diagnostics,
                                 correctionsDirectory: root.appendingPathComponent("dated-corrections"), keyProvider: { key })
    let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
    let first = SpeechDiagnosticTrace(samples: [0.25], configuration: [:])
    let second = SpeechDiagnosticTrace(samples: [0.5], configuration: [:])
    let firstURL = try writer.save(first.snapshot(outcome: "ok"))!
    let secondURL = try writer.save(second.snapshot(outcome: "ok"))!
    let recent = Date()
    try FileManager.default.setAttributes([.creationDate: recent.addingTimeInterval(-120), .modificationDate: recent], ofItemAtPath: firstURL.path)
    try FileManager.default.setAttributes([.creationDate: recent.addingTimeInterval(-60), .modificationDate: recent.addingTimeInterval(-30)], ofItemAtPath: secondURL.path)
    try check(store.list().map(\.id) == [second.id, first.id], "Порядок записей зависит от времени создания, а не изменения файла")
}

func checkAutomaticReview(root: URL, key: Data) throws {
    let diagnostics = root.appendingPathComponent("automatic-diagnostics")
    let corrections = root.appendingPathComponent("automatic-corrections")
    let store = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { key })
    let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
    let trace = SpeechDiagnosticTrace(samples: [0.25], configuration: [:])
    let source = try writer.save(trace.snapshot(outcome: "ok"))!
    let created = ISO8601DateFormatter().date(from: "2026-11-01T00:30:00+03:00")!
    try FileManager.default.setAttributes([.creationDate: created, .modificationDate: Date()], ofItemAtPath: source.path)
    try store.saveConfirmed(id: trace.id, reference: "проверенная фраза", editedText: "", silence: false)
    let document = try store.load(id: trace.id)
    try check(document.createdAt == created, "Сохраняется время создания исходной записи")
    try check(document.correction?.sessionID == "recorded-2026-11-01", "Автоматическая группа учитывает границу дня MSK")
    try check(document.correction?.split == "dev", "Новые примеры готовы для настройки без ручного выбора")
    try check(document.correction?.createdAt == created, "Дата сохранена внутри зашифрованной правки")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.path)
    try store.saveConfirmed(id: trace.id, reference: "уточнённая фраза", editedText: "Уточнённая фраза.", silence: false)
    try check(store.load(id: trace.id).createdAt == created, "Повторное исправление не меняет время создания записи")
    let output = root.appendingPathComponent("automatic-export")
    try check(store.exportConfirmed(to: output) == 1, "Автоматическое подтверждение экспортируется")
    let row = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("manifest.jsonl"))) as! [String: Any]
    try check(row["created_at"] as? String == "2026-11-01T00:30:00.000+03:00", "Экспорт сохраняет время создания с часовым поясом")
    try check(row["session_id"] as? String == "recorded-2026-11-01", "Экспорт группирует по дню создания записи")
    rejects("Пустой эталон по-прежнему требует явного подтверждения тишины") {
        try store.saveConfirmed(id: trace.id, reference: "", editedText: "", silence: false)
    }
    try store.saveConfirmed(id: trace.id, reference: "", editedText: "", silence: true)
    try check(store.load(id: trace.id).correction?.silence == true, "Тишина сохраняется без сессии и назначения")

    let legacy: [String: Any] = ["id": trace.id.uuidString, "reference": "старый эталон", "editedText": "",
                               "sessionID": "old-session", "split": "test", "silence": false]
    let sealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: legacy), using: SymmetricKey(data: key)).combined!
    try sealed.write(to: corrections.appendingPathComponent(trace.id.uuidString + ".enc"))
    try check(store.load(id: trace.id).correction?.reference == "старый эталон", "Правки без нового поля даты продолжают открываться")
    try store.saveConfirmed(id: trace.id, reference: "обновлённый эталон", editedText: "", silence: false)
    let updated = try store.load(id: trace.id).correction!
    try check(updated.sessionID == "old-session" && updated.split == "test", "Ручная группировка прежних правок сохраняется")
    try check(updated.createdAt == created, "При пересохранении старой правки дата берётся из исходной записи")
    print("PASS: автоматическая дата, группы MSK, сохранение без ручной разметки, совместимость старых правок")
}

func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { fatalError(message) }
}
func rejects(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError(message) } catch { }
}
func checkConfirmedRetention(root: URL, key: Data) throws {
    let folder = root.appendingPathComponent("confirmed-retention")
    let diagnostics = folder.appendingPathComponent("speech-diagnostics")
    let corrections = folder.appendingPathComponent("speech-corrections")
    let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
    let review = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { key })
    let trace = SpeechDiagnosticTrace(samples: [0.125, -0.25], configuration: [:])
    let audio = try writer.save(trace.snapshot(outcome: "ok"))!
    try review.saveConfirmed(id: trace.id, reference: "проверенный звук", editedText: "", silence: false)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: audio.path)
    let reopened = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { fatalError("Очистка не читает ключ") })
    try reopened.prune(maximumRecords: 0)
    try reopened.deleteRecords()
    try check(review.load(id: trace.id).correction?.reference == "проверенный звук", "Подтверждение переживает очистку и повторное открытие")
    try check(review.audio(id: trace.id).suffix(8) == trace.snapshot(outcome: "ok").pcmFloat32LE, "Подтверждённое аудио после очистки совпадает побайтно")
    try check(review.exportConfirmed(to: folder.appendingPathComponent("export")) == 1, "Старое подтверждённое аудио остаётся доступно для экспорта")
    print("PASS: подтверждение и исходный звук сохраняются после срока, нулевого лимита и очистки")
}
/// Сохраняет пример с трассой диктовки и заданным возрастом файла.
@discardableResult
func saveDictation(writer: SpeechDiagnosticsStore, outcome: String, dictionary: String?, output: String?,
                   age: TimeInterval, now: Date) throws -> UUID {
    let trace = SpeechDiagnosticTrace(samples: [0.25, -0.5], configuration: [:])
    if let dictionary { trace.record("dictionary", text: dictionary) }
    if let output { trace.record("output_options", text: output) }
    let url = try writer.save(trace.snapshot(outcome: outcome))!
    try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-age), .modificationDate: now], ofItemAtPath: url.path)
    return trace.id
}

func checkImplicitConfirmation(root: URL, key: Data) throws {
    let folder = root.appendingPathComponent("implicit")
    let diagnostics = folder.appendingPathComponent("speech-diagnostics")
    let corrections = folder.appendingPathComponent("speech-corrections")
    let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
    let store = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { key })
    let now = Date()
    let hour: TimeInterval = 3600
    let minimum = 12 * hour
    let matured = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "текст диктовки", output: "Текст диктовки.", age: 13 * hour, now: now)
    let young = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "свежая фраза", output: nil, age: 11 * hour, now: now)
    let historyOnly = try saveDictation(writer: writer, outcome: "history_only", dictionary: "только история", output: nil, age: 20 * hour, now: now)
    let empty = try saveDictation(writer: writer, outcome: "empty", dictionary: "пусто", output: nil, age: 20 * hour, now: now)
    let secure = try saveDictation(writer: writer, outcome: "secure_input_history_only", dictionary: "пароль", output: nil, age: 20 * hour, now: now)
    let blank = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "  ", output: nil, age: 20 * hour, now: now)
    let noStage = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: nil, output: nil, age: 20 * hour, now: now)
    try check(store.list().allSatisfy { $0.source == nil }, "До прохода ничего не подтверждено")
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 1, "Подтверждается только созревшая вставленная диктовка")
    let document = try store.load(id: matured)
    try check(document.correction?.reference == "текст диктовки", "Эталон неявного — текст словаря")
    try check(document.correction?.editedText == "Текст диктовки.", "Напечатанный текст — стадия output_options")
    try check(document.correction?.source == "implicit", "Источник неявного подтверждения")
    try check(document.correction?.silence == false, "Неявное подтверждение — речь")
    try check(document.correction?.split == "dev", "Неявное подтверждение попадает в dev")
    try check(store.list().first(where: { $0.id == matured })?.source == "implicit", "Список показывает неявный источник")
    for id in [young, historyOnly, empty, secure, blank, noStage] {
        try check(store.load(id: id).correction == nil, "Неподходящие примеры не подтверждаются")
        try check(store.list().first(where: { $0.id == id })?.source == nil, "Неподтверждённый пример без источника")
    }
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 0, "Повторный проход ничего не подтверждает")
    try check(store.confirmMatured(now: now.addingTimeInterval(2 * hour), minimumAge: minimum).confirmed == 1, "Пример подтверждается, когда созреет")
    let fallback = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "без оформления", output: nil, age: 13 * hour, now: now)
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 1, "Проход подтверждает пример без output_options")
    try check(store.load(id: fallback).correction?.editedText == "без оформления", "Без output_options editedText равен словарю")

    try store.saveConfirmed(id: matured, reference: "исправленный текст", editedText: "Исправленный текст.", silence: false)
    let explicit = try store.load(id: matured).correction
    try check(explicit?.source == "explicit" && explicit?.reference == "исправленный текст", "Явная правка перезаписывает неявную")
    try check(store.list().first(where: { $0.id == matured })?.source == "explicit", "Список показывает явный источник")
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 0, "Явная правка не затирается проходом")
    try check(store.load(id: matured).correction?.source == "explicit", "Источник остался явным")

    // Отказ: удалённая неявная не воскресает, явная правка снимает отказ.
    let refused = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "отказная", output: nil, age: 13 * hour, now: now)
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 1, "Отказной пример сначала подтверждается")
    try store.removeCorrection(id: refused)
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 0, "Удалённая неявная не подтверждается снова")
    try check(store.load(id: refused).correction == nil, "После отказа эталона нет")
    let refusals = folder.appendingPathComponent("speech-review-refusals.enc")
    try check(FileManager.default.fileExists(atPath: refusals.path), "Отказы лежат рядом с каталогом эталонов")
    let refusalMode = try FileManager.default.attributesOfItem(atPath: refusals.path)[.posixPermissions] as! NSNumber
    try check(refusalMode.intValue == 0o600, "Файл отказов закрыт")
    try check(!String(decoding: Data(contentsOf: refusals), as: UTF8.self).contains(refused.uuidString), "Отказы зашифрованы")
    try store.saveConfirmed(id: refused, reference: "вручную", editedText: "", silence: false)
    try check(store.load(id: refused).correction?.source == "explicit", "После отказа явная правка работает")
    // Удаление явного эталона тоже заносит id в отказы.
    try store.removeCorrection(id: refused)
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 0, "Любое удаление эталона заносит id в отказы")

    // Старый JSON без source читается как явный.
    let legacyID = try saveDictation(writer: writer, outcome: "history_only", dictionary: nil, output: nil, age: 0, now: now)
    let legacy: [String: Any] = ["id": legacyID.uuidString, "reference": "старый", "editedText": "",
                               "sessionID": "legacy", "split": "dev", "silence": false]
    let sealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: legacy), using: SymmetricKey(data: key)).combined!
    try sealed.write(to: corrections.appendingPathComponent(legacyID.uuidString + ".enc"))
    try check(store.load(id: legacyID).correction?.source == "explicit", "Старый эталон без source читается как явный")
    try check(store.list().first(where: { $0.id == legacyID })?.source == "explicit", "Список: старый эталон явный")

    // Повреждённый файл не валит проход.
    let corruptURL = diagnostics.appendingPathComponent(UUID().uuidString + ".enc")
    try Data(repeating: 1, count: 64).write(to: corruptURL)
    try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-20 * hour)], ofItemAtPath: corruptURL.path)
    let good = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "после повреждённого", output: nil, age: 14 * hour, now: now)
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 1, "Повреждённый пример пропускается, остальные подтверждены")
    try check(store.load(id: good).correction?.source == "implicit", "Подходящий пример рядом с повреждённым подтверждён")

    // Выгрузка различает источник.
    let output = folder.appendingPathComponent("export")
    try check(store.exportConfirmed(to: output) >= 3, "Выгрузка содержит явные и неявные")
    let rows = try String(contentsOf: output.appendingPathComponent("manifest.jsonl"), encoding: .utf8).split(separator: "\n")
        .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    func source(_ id: UUID) -> String? { rows.first { $0["id"] as? String == id.uuidString }?["reference_source"] as? String }
    try check(source(matured) == "explicit_user_confirmation", "Явная строка выгрузки")
    try check(source(legacyID) == "explicit_user_confirmation", "Старая строка выгрузки явная")
    try check(source(good) == "implicit_unedited", "Неявная строка выгрузки")
    // Список не читает ключ: источник берётся из открытой метки.
    struct NoKey: Error {}
    let keyless = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { throw NoKey() })
    let keylessItems = try keyless.list()
    try check(keylessItems.first(where: { $0.id == good })?.source == "implicit", "Список без ключа показывает неявный источник")
    try check(keylessItems.first(where: { $0.id == matured })?.source == "explicit", "Список без ключа показывает явный источник")
    try check(keylessItems.first(where: { $0.id == legacyID })?.hasSavedCorrection == true, "Список без ключа видит сохранённые")

    // Сбой записи отказа не удаляет эталон.
    rejects("Без ключа отказ не записывается") { try keyless.removeCorrection(id: good) }
    try check(store.load(id: good).correction?.source == "implicit", "Эталон остаётся, если отказ не записан")

    // Нечитаемый файл отказов: карантин, неявное выключено, явные действия не блокируются.
    let fresh = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "после порчи", output: nil, age: 13 * hour, now: now)
    try Data(repeating: 9, count: 64).write(to: refusals)
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 0, "Нечитаемые отказы выключают неявное подтверждение")
    try check(!FileManager.default.fileExists(atPath: refusals.path), "Нечитаемый файл отказов вынесен")
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("speech-review-refusals.corrupt-") }
    try check(quarantined.count == 1, "Нечитаемый файл сохранён в карантине")
    try check(store.confirmMatured(now: now, minimumAge: minimum).confirmed == 0, "Без нового файла отказов неявное остаётся выключенным")
    try store.saveConfirmed(id: fresh, reference: "явно после порчи", editedText: "", silence: false)
    try check(store.load(id: fresh).correction?.source == "explicit", "Явное сохранение не блокируется порчей отказов")
    try check(FileManager.default.fileExists(atPath: refusals.path), "Явное действие создало новый файл отказов")
    try store.removeCorrection(id: good)
    try check(store.load(id: good).correction == nil, "Удаление работает после порчи отказов")
    try Data(repeating: 9, count: 64).write(to: refusals)
    try store.removeCorrection(id: fresh)
    try check(store.load(id: fresh).correction == nil, "Удаление при нечитаемых отказах не блокируется")
    _ = try store.confirmMatured(now: now, minimumAge: minimum)
    try check(store.load(id: fresh).correction == nil, "Удалённый после порчи не воскресает")
    print("PASS: неявное подтверждение, отказы, источник эталона, повреждённые примеры, выгрузка")
}
/// Ключ с конечным числом выдач: имитирует сбой Keychain посреди операции и считает обращения.
final class CountingKey {
    struct Unavailable: Error {}
    let key: Data
    var calls = 0
    var remaining = Int.max
    init(_ key: Data) { self.key = key }
    func next() throws -> Data {
        calls += 1
        guard remaining > 0 else { throw Unavailable() }
        remaining -= 1
        return key
    }
}

func quarantinedRefusals(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("speech-review-refusals.corrupt-") }
}

func checkImplicitPassCost(root: URL, key: Data) throws {
    let folder = root.appendingPathComponent("implicit-cost")
    let diagnostics = folder.appendingPathComponent("speech-diagnostics")
    let corrections = folder.appendingPathComponent("speech-corrections")
    let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
    let plain = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { key })
    let counter = CountingKey(key)
    let store = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: counter.next)
    let now = Date()
    let hour: TimeInterval = 3600
    for index in 0..<30 {
        let id = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "фраза \(index)", output: nil, age: 20 * hour, now: now)
        try plain.saveConfirmed(id: id, reference: "правка \(index)", editedText: "", silence: false)
    }
    try plain.removeCorrection(id: UUID())
    var fresh: [UUID] = []
    for index in 0..<3 {
        fresh.append(try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "новая \(index)", output: nil, age: 13 * hour, now: now))
    }
    for _ in 0..<5 { try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "молодая", output: nil, age: hour, now: now) }
    // Нечитаемый эталон не блокирует проход: пропускается и считается.
    try Data(repeating: 3, count: 64).write(to: corrections.appendingPathComponent(UUID().uuidString + ".enc"))
    let pass = try store.confirmMatured(now: now, minimumAge: 12 * hour)
    try check(pass.confirmed == 3, "Нечитаемый эталон не мешает подтверждать остальные")
    try check(pass.unreadableCorrections == 1, "Нечитаемые эталоны посчитаны")
    try check(fresh.allSatisfy { (try? plain.load(id: $0).correction?.source) == "implicit" }, "Созревшие подтверждены неявно")
    try check(counter.calls <= 2 + pass.confirmed, "Ключ читается ограниченное число раз за проход (\(counter.calls))")
    counter.calls = 0
    let idle = try store.confirmMatured(now: now, minimumAge: 12 * hour)
    try check(idle.confirmed == 0 && counter.calls <= 2, "Холостой проход не расшифровывает эталоны (\(counter.calls))")
    print("PASS: проход неявного подтверждения читает ключ ограниченно и терпит нечитаемые эталоны")
}

func checkRefusalsKeyFailure(root: URL, key: Data) throws {
    let folder = root.appendingPathComponent("refusals-key")
    let diagnostics = folder.appendingPathComponent("speech-diagnostics")
    let corrections = folder.appendingPathComponent("speech-corrections")
    let refusals = folder.appendingPathComponent("speech-review-refusals.enc")
    let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
    let plain = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { key })
    let counter = CountingKey(key)
    let flaky = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: counter.next)
    let now = Date()
    let hour: TimeInterval = 3600
    // Старый формат отказов — массив id — продолжает читаться.
    let refused = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "отказ", output: nil, age: 20 * hour, now: now)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let legacy = try AES.GCM.seal(JSONEncoder().encode([refused]), using: SymmetricKey(data: key)).combined!
    try legacy.write(to: refusals)
    let target = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "цель", output: nil, age: 20 * hour, now: now)
    try plain.saveConfirmed(id: target, reference: "цель", editedText: "", silence: false)

    // Ключ выдан один раз, затем Keychain недоступен: файл отказов не уходит в карантин.
    counter.remaining = 1
    rejects("Без ключа отказ не записывается") { try flaky.removeCorrection(id: target) }
    try check(FileManager.default.fileExists(atPath: refusals.path), "Сбой ключа не выносит файл отказов")
    try check(quarantinedRefusals(folder).isEmpty, "Сбой ключа не создаёт карантин")
    try check(plain.load(id: target).correction != nil, "Эталон остаётся при сбое ключа")
    counter.remaining = 0
    rejects("Проход без ключа падает, а не пропускает отказы") { _ = try flaky.confirmMatured(now: now, minimumAge: 12 * hour) }
    try check(quarantinedRefusals(folder).isEmpty, "Недоступный ключ не карантинит отказы при проходе")
    counter.remaining = 1
    _ = try? flaky.confirmMatured(now: now, minimumAge: 12 * hour)
    try check(quarantinedRefusals(folder).isEmpty && FileManager.default.fileExists(atPath: refusals.path), "Проход с одной выдачей ключа не карантинит отказы")
    _ = try plain.confirmMatured(now: now, minimumAge: 12 * hour)
    try check(plain.load(id: refused).correction == nil, "Отказ из старого файла соблюдается")
    try check(quarantinedRefusals(folder).isEmpty, "Старый формат отказов читается без карантина")
    print("PASS: сбой ключа не уничтожает отказы, старый формат отказов читается")
}

func checkRefusalsWatermark(root: URL, key: Data) throws {
    let folder = root.appendingPathComponent("refusals-watermark")
    let diagnostics = folder.appendingPathComponent("speech-diagnostics")
    let corrections = folder.appendingPathComponent("speech-corrections")
    let refusals = folder.appendingPathComponent("speech-review-refusals.enc")
    let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
    let store = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { key })
    let now = Date()
    let hour: TimeInterval = 3600
    let old = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "до порчи", output: nil, age: 13 * hour, now: now)
    try store.removeCorrection(id: UUID())
    try Data(repeating: 9, count: 64).write(to: refusals)
    let paused = try store.confirmMatured(now: now, minimumAge: 12 * hour)
    try check(paused.confirmed == 0 && paused.paused, "Карантин отказов приостанавливает проход")
    try store.removeCorrection(id: UUID())
    try check(FileManager.default.fileExists(atPath: refusals.path), "Явное действие создало новый файл отказов")
    try check(store.confirmMatured(now: now, minimumAge: 12 * hour).confirmed == 0, "Примеры до карантина не подтверждаются неявно")
    try check(store.load(id: old).correction == nil, "Старый пример не подтверждён после карантина")
    let later = try saveDictation(writer: writer, outcome: "insertion_requested", dictionary: "после порчи", output: nil, age: 0, now: now)
    // Время создания после отметки: сначала сдвигаем изменение, иначе система ограничит создание им.
    let laterURL = diagnostics.appendingPathComponent(later.uuidString + ".enc")
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(120)], ofItemAtPath: laterURL.path)
    try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(60)], ofItemAtPath: laterURL.path)
    try check(store.confirmMatured(now: now.addingTimeInterval(13 * hour), minimumAge: 12 * hour).confirmed == 1, "Новые примеры после карантина подтверждаются")
    try check(store.load(id: later).correction?.source == "implicit", "Пример после отметки подтверждён неявно")
    try check(store.load(id: old).correction == nil, "Отметка карантина переживает следующие проходы")
    // Отметка сохраняется при последующих записях отказов.
    try store.removeCorrection(id: UUID())
    try check(store.confirmMatured(now: now.addingTimeInterval(13 * hour), minimumAge: 12 * hour).confirmed == 0, "Отметка не теряется при перезаписи отказов")
    try check(store.load(id: old).correction == nil, "Старый пример остаётся неподтверждённым")
    let names = try quarantinedRefusals(folder)
    try check(names.count == 1 && names[0].count > "speech-review-refusals.corrupt-.enc".count + 36, "Имя карантина уникально (UUID)")
    print("PASS: отметка карантина отказов блокирует неявное подтверждение старых примеров")
}

let requested = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory.appendingPathComponent("speech-review-" + UUID().uuidString)
let physicalParent = realpath(requested.deletingLastPathComponent().path, nil)!
defer { free(physicalParent) }
let root = URL(fileURLWithPath: String(cString: physicalParent)).appendingPathComponent(requested.lastPathComponent)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { if CommandLine.arguments.count == 1 { try? FileManager.default.removeItem(at: root) } }
let key = Data(repeating: 7, count: 32)
try checkConfirmedRetention(root: root, key: key)
try checkCreationOrder(root: root, key: key)
try checkAutomaticReview(root: root, key: key)
try checkImplicitConfirmation(root: root, key: key)
try checkImplicitPassCost(root: root, key: key)
try checkRefusalsKeyFailure(root: root, key: key)
try checkRefusalsWatermark(root: root, key: key)
let diagnostics = root.appendingPathComponent("diagnostics")
let corrections = root.appendingPathComponent("corrections")
let store = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { key })
let trace = SpeechDiagnosticTrace(samples: [0, 0.125, -0.75], configuration: [:])
trace.record("raw", text: "секретный черновик")
let snapshot = trace.snapshot(outcome: "ok")
let writer = SpeechDiagnosticsStore(directory: diagnostics, enabled: true, keyProvider: { key })
_ = try writer.save(snapshot)
let listing = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { fatalError("Список не должен читать ключ") })
try check(listing.list().map(\.id) == [trace.id], "Список читает метаданные")
try check(store.load(id: trace.id).correction == nil, "Черновик не подтверждён")
try check(store.audio(id: trace.id).suffix(snapshot.pcmFloat32LE.count) == snapshot.pcmFloat32LE, "WAV сохраняет PCM побайтно")
let correction = SpeechReviewCorrection(id: trace.id, reference: "секретная расшифровка", editedText: "Отредактированный текст", sessionID: "session-1", split: "dev", silence: false)
try store.save(correction)
try check(listing.list().first(where: { $0.id == trace.id })?.hasSavedCorrection == true, "Сохранённая правка видна без расшифровки и доступа к ключу")
try check(store.load(id: trace.id).correction?.reference == correction.reference, "Подтверждение читается после шифрования")
let encrypted = try Data(contentsOf: corrections.appendingPathComponent(trace.id.uuidString + ".enc"))
try check(!String(decoding: encrypted, as: UTF8.self).contains(correction.reference), "Открытый текст не сохраняется")
let permissions = try FileManager.default.attributesOfItem(atPath: corrections.path)[.posixPermissions] as! NSNumber
try check(permissions.intValue == 0o700, "Каталог закрыт")
let filePermissions = try FileManager.default.attributesOfItem(atPath: corrections.appendingPathComponent(trace.id.uuidString + ".enc").path)[.posixPermissions] as! NSNumber
try check(filePermissions.intValue == 0o600, "Файл закрыт")
try store.save(SpeechReviewCorrection(id: trace.id, reference: correction.reference, editedText: "Новая редакция", sessionID: correction.sessionID, split: correction.split, silence: false))
try check(store.load(id: trace.id).correction?.editedText == "Новая редакция", "Исправление заменяется атомарно")
let second = SpeechDiagnosticTrace(samples: [0], configuration: [:])
_ = try writer.save(second.snapshot(outcome: "ok"))
rejects("Одна сессия не пересекает выборки") {
    try store.save(SpeechReviewCorrection(id: second.id, reference: "другой", editedText: "", sessionID: "session-1", split: "train", silence: false))
}
for invalid in [
    SpeechReviewCorrection(id: trace.id, reference: " ", editedText: "", sessionID: "s", split: "dev", silence: false),
    SpeechReviewCorrection(id: trace.id, reference: "слова", editedText: "", sessionID: "s", split: "dev", silence: true),
    SpeechReviewCorrection(id: trace.id, reference: "слова", editedText: "", sessionID: " ", split: "dev", silence: false),
    SpeechReviewCorrection(id: trace.id, reference: "слова", editedText: "", sessionID: "s", split: "other", silence: false)
] { rejects("Неверная разметка отклоняется") { try store.save(invalid) } }
let export = root.appendingPathComponent("export")
try check(store.exportConfirmed(to: export) == 1, "Экспортируются только подтверждённые")
let lines = try String(contentsOf: export.appendingPathComponent("manifest.jsonl"), encoding: .utf8).split(separator: "\n")
let manifest = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
try check(manifest["reference"] as? String == correction.reference, "Эталон не подменён редакторским текстом")
try check(manifest["reference_confirmed"] as? Bool == true, "Экспорт явно подтверждён")
try check(manifest["kind"] as? String == "speech", "Экспорт указывает тип записи")
try check(manifest["duration_seconds"] as? Double == 3.0 / 16000, "Экспорт указывает точную длительность")
try check((manifest["input_wav_sha256"] as? String)?.count == 64, "Экспорт содержит хеш WAV")
try check((manifest["source_trace_sha256"] as? String)?.count == 64, "Экспорт содержит происхождение")
rejects("Экспорт не перезаписывается") { _ = try store.exportConfirmed(to: export) }
rejects("Экспорт в репозиторий запрещён") { _ = try store.exportConfirmed(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("review-test-export")) }
let originalWorkingDirectory = FileManager.default.currentDirectoryPath
try check(FileManager.default.changeCurrentDirectoryPath(root.path), "Переходим в каталог вне Git")
try check(store.exportConfirmed(to: root.appendingPathComponent("nonrepo-export")) == 1, "Экспорт внутри рабочего каталога вне Git разрешён")
try check(FileManager.default.changeCurrentDirectoryPath(originalWorkingDirectory), "Восстанавливаем рабочий каталог")
try store.save(SpeechReviewCorrection(id: second.id, reference: "другой эталон", editedText: "", sessionID: "session-2", split: "dev", silence: false))
try FileManager.default.removeItem(at: diagnostics.appendingPathComponent(trace.id.uuidString + ".enc"))
let orphan = root.appendingPathComponent("orphan-export")
rejects("Осиротевшее подтверждение не экспортируется") { _ = try store.exportConfirmed(to: orphan) }
try check(!FileManager.default.fileExists(atPath: orphan.path), "Неудачный экспорт очищен")
let cleanupWithoutKey = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { fatalError("Очистка не должна читать ключ") })
let unsafeSource = diagnostics.appendingPathComponent(trace.id.uuidString + ".enc")
try FileManager.default.createSymbolicLink(at: unsafeSource, withDestinationURL: export.appendingPathComponent("manifest.jsonl"))
rejects("Очистка отклоняет симлинк исходной записи") { _ = try cleanupWithoutKey.removeOrphanCorrections() }
try check(FileManager.default.fileExists(atPath: corrections.appendingPathComponent(trace.id.uuidString + ".enc").path), "Небезопасный источник не вызывает удаление эталона")
try FileManager.default.removeItem(at: unsafeSource)
let unsafeCorrection = corrections.appendingPathComponent(UUID().uuidString + ".enc")
try FileManager.default.createSymbolicLink(at: unsafeCorrection, withDestinationURL: export.appendingPathComponent("manifest.jsonl"))
rejects("Очистка отклоняет симлинк эталона") { _ = try cleanupWithoutKey.removeOrphanCorrections() }
try FileManager.default.removeItem(at: unsafeCorrection)
try check(cleanupWithoutKey.removeOrphanCorrections() == 1, "Удаляется только эталон без исходной диагностики")
try check(store.load(id: second.id).correction != nil, "Эталон с исходной диагностикой сохраняется")
try check(store.exportConfirmed(to: root.appendingPathComponent("after-orphan-cleanup")) == 1, "После явной очистки экспорт работает")
try check(cleanupWithoutKey.removeOrphanCorrections() == 0, "Повторная очистка ничего не удаляет")
try store.removeCorrection(id: second.id)
try check(listing.list().first(where: { $0.id == second.id })?.hasSavedCorrection == false, "Удалённая правка больше не помечена сохранённой")
rejects("Пустой экспорт запрещён") { _ = try store.exportConfirmed(to: root.appendingPathComponent("empty")) }
let symlink = root.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: diagnostics)
let linked = SpeechReviewStore(diagnosticsDirectory: symlink, correctionsDirectory: corrections, keyProvider: { key })
rejects("Симлинк каталога запрещён") { _ = try linked.list() }
let linkedFile = diagnostics.appendingPathComponent(UUID().uuidString + ".enc")
try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: export.appendingPathComponent("manifest.jsonl"))
rejects("Симлинк записи запрещён") { _ = try store.list() }
try FileManager.default.removeItem(at: linkedFile)
let sameDirectory = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: diagnostics, keyProvider: { key })
rejects("Эталон не перезаписывает исходную диагностику") {
    try sameDirectory.save(SpeechReviewCorrection(id: second.id, reference: "слова", editedText: "", sessionID: "s", split: "dev", silence: false))
}
let wrongKey = SpeechReviewStore(diagnosticsDirectory: diagnostics, correctionsDirectory: corrections, keyProvider: { Data(repeating: 8, count: 32) })
rejects("Неверный ключ не открывает диагностику") { _ = try wrongKey.load(id: second.id) }
try store.save(SpeechReviewCorrection(id: second.id, reference: "", editedText: "", sessionID: "silence-session", split: "dev", silence: true))
let silenceExport = root.appendingPathComponent("silence-export")
try check(store.exportConfirmed(to: silenceExport) == 1, "Тишина экспортируется с пустым эталоном")
let silenceRow = try JSONSerialization.jsonObject(with: Data(contentsOf: silenceExport.appendingPathComponent("manifest.jsonl"))) as! [String: Any]
try check(silenceRow["kind"] as? String == "silence", "Тишина отмечена для оценщика")
try store.removeCorrection(id: second.id)
let sparse = diagnostics.appendingPathComponent(UUID().uuidString + ".enc")
_ = FileManager.default.createFile(atPath: sparse.path, contents: nil)
let sparseHandle = try FileHandle(forWritingTo: sparse)
try sparseHandle.truncate(atOffset: 256 * 1024 * 1024 + 1)
try sparseHandle.close()
rejects("Большой шифротекст отклоняется до выделения памяти") { _ = try store.load(id: UUID(uuidString: sparse.deletingPathExtension().lastPathComponent)!) }
try FileManager.default.removeItem(at: sparse)
let invalid = SpeechDiagnosticTrace.Snapshot(schema: 2, id: second.id, sampleRate: 16000, channels: 1, pcmFormat: "IEEE754-float32-little-endian", pcmFloat32LE: Data(repeating: 0, count: 4), configuration: [:], events: [], outcome: "ok")
try FileManager.default.removeItem(at: diagnostics.appendingPathComponent(second.id.uuidString + ".enc"))
_ = try writer.save(invalid)
rejects("Неверная схема закрывает чтение") { _ = try store.load(id: second.id) }
for (rate, channels, pcm) in [(8000, 1, Data(repeating: 0, count: 4)), (16000, 2, Data(repeating: 0, count: 4)), (16000, 1, Data([0])), (16000, 1, Data([0, 0, 128, 127]))] {
    let bad = SpeechDiagnosticTrace.Snapshot(schema: 1, id: second.id, sampleRate: rate, channels: channels, pcmFormat: "IEEE754-float32-little-endian", pcmFloat32LE: pcm, configuration: [:], events: [], outcome: "ok")
    try FileManager.default.removeItem(at: diagnostics.appendingPathComponent(second.id.uuidString + ".enc"))
    _ = try writer.save(bad)
    rejects("Неверные частота, каналы и PCM отклоняются") { _ = try store.audio(id: second.id) }
}
print("PASS: зашифрованные исправления, выборки, WAV, экспорт, права, симлинки, схема, лимиты, тишина")
