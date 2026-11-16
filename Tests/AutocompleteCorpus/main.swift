import Foundation
import CryptoKit

// Заглушки зависимостей (в сборке приложения они из Logger.swift и CompletionText.swift).
func kbLog(_ message: String) {}
enum CompletionText {
    static func redactSecrets(_ text: String) -> String {
        text.replacingOccurrences(of: "sk-[A-Za-z0-9]{10,}", with: "•••", options: .regularExpression)
    }
}

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    if cond { print("ok   \(msg)") } else { print("FAIL \(msg)"); failures += 1 }
}

let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("speakey-corpus-test-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: dir) }
let key = SymmetricKey(data: Data(repeating: 7, count: 32))
let corpus = PersonalCorpus(directory: dir, keyProvider: { key })

// Короткие тексты не пишутся
corpus.add("слишком коротко", bundleID: "a.b")
expect(corpus.count == 0, "тексты <20 симв. не пишутся")

let t1 = "Завтра созвонимся по релизу Speakey и обсудим автодополнение"
let t2 = "Отправил отчёт по релизу, жду ответа от команды"
let t3 = "Купить молоко и хлеб после работы сегодня вечером"
let t4 = "Мой ключ sk-abcdefghijklmnopqrstuv123 не показывать никому"
corpus.add(t1, bundleID: "com.tg")
corpus.add(t2, bundleID: "com.tg")
corpus.add(t3, bundleID: "com.mail")
corpus.add(t4, bundleID: "com.mail")
expect(corpus.count == 4, "4 записи")

// Шифрование на диске
let raw = try! Data(contentsOf: dir.appendingPathComponent("corpus.bin"))
expect(raw.range(of: "релизу".data(using: .utf8)!) == nil, "файл не содержит UTF-8 исходного текста")
expect(raw.range(of: "Speakey".data(using: .utf8)!) == nil, "файл не содержит ASCII-слов")
expect(raw.range(of: "sk-abc".data(using: .utf8)!) == nil, "секрет не на диске в открытом виде")

// Секреты вырезаны и в памяти
let all = corpus.similar(to: "ключ не показывать никому", limit: 5)
expect(!all.contains { $0.contains("sk-abc") }, "секрет вырезан")

// similar
let sim = corpus.similar(to: "Что там с релизом по отчёту, готов ли релизу", limit: 1)
expect(sim.count == 1 && (sim[0] == t1 || sim[0] == t2), "similar находит фрагмент с общими словами")
expect(corpus.similar(to: "xyz qqq", limit: 3).isEmpty, "similar без пересечения пуст")

// topTerms
let terms = corpus.topTerms(limit: 5)
expect(terms.contains("релизу"), "topTerms: повторяющееся слово")
expect(!terms.contains("молоко"), "topTerms: разовые слова не попадают")

// Перезагрузка с диска тем же ключом
let reloaded = PersonalCorpus(directory: dir, keyProvider: { key })
expect(reloaded.count == 4, "перечитывание с диска")
let wrong = PersonalCorpus(directory: dir, keyProvider: { SymmetricKey(data: Data(repeating: 9, count: 32)) })
expect(wrong.count == 0, "чужой ключ не читает файл")

// Просмотр корпуса и удаление конкретной записи.
let snapshot = corpus.snapshot()
expect(snapshot.available && snapshot.records.count == 4, "снимок содержит все расшифрованные записи")
expect(snapshot.sourceCounts["com.tg"] == 2 && snapshot.sourceCounts["com.mail"] == 2, "счётчики по источникам")
expect(corpus.snapshot(bundleID: "com.tg").records.count == 2, "фильтр по приложению")
let sample = snapshot.records.first { $0.text == t1 }!
expect(corpus.snapshot().records.contains { $0.id == sample.id }, "идентификатор стабилен между снимками")
expect(corpus.remove(id: sample.id), "удаление выбранной записи успешно")
expect(corpus.count == 3 && !corpus.snapshot().records.contains { $0.id == sample.id }, "удалена только выбранная запись")
expect(!corpus.remove(id: UUID()), "несуществующая запись не сообщает об удалении")
corpus.add(t1, bundleID: "com.tg")

// Чужой или недоступный ключ не разрешает затереть существующий файл.
let beforeWrong = try! Data(contentsOf: dir.appendingPathComponent("corpus.bin"))
expect(!wrong.snapshot().available, "ошибка расшифровки видна в снимке")
expect(!wrong.add("Этот новый текст не должен затереть прежний корпус", bundleID: "wrong"), "чужой ключ запрещает запись")
expect(!wrong.removeAll(), "чужой ключ запрещает очистку")
expect(try! Data(contentsOf: dir.appendingPathComponent("corpus.bin")) == beforeWrong, "файл с чужим ключом сохранён побайтно")
let noKey = PersonalCorpus(directory: dir, keyProvider: { nil })
expect(!noKey.snapshot().available && !noKey.remove(bundleID: "com.tg"), "недоступный ключ не позволяет удалять данные")

let missingKeyDir = dir.appendingPathComponent("missing-key")
let emptyWithoutKey = PersonalCorpus(directory: missingKeyDir, keyProvider: { nil })
expect(!emptyWithoutKey.snapshot().available, "нет ключа и файла: состояние недоступности явно")
let permissions = try! FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("corpus.bin").path)[.posixPermissions] as! NSNumber
expect(permissions.intValue == 0o600, "зашифрованный файл доступен только владельцу")
// Старый формат без идентификаторов читается и допускает точечное удаление.
let legacyDir = dir.appendingPathComponent("legacy")
try! FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
let legacy = try! JSONSerialization.data(withJSONObject: [
    ["text": t1, "bundleID": "com.tg", "date": 100.0],
    ["text": t3, "bundleID": "com.mail", "date": 200.0]
])
let legacyBlob = try! AES.GCM.seal(legacy, using: key).combined!
try! legacyBlob.write(to: legacyDir.appendingPathComponent("corpus.bin"))
let legacyCorpus = PersonalCorpus(directory: legacyDir, keyProvider: { key })
let legacyRecord = legacyCorpus.snapshot().records.first!
expect(legacyRecord.bundleID == "com.mail", "старые записи сортируются от новых к старым")
expect(legacyCorpus.remove(id: legacyRecord.id), "удаление старой записи без id")
expect(PersonalCorpus(directory: legacyDir, keyProvider: { key }).count == 1, "удаление старой записи сохранено")

// Ошибка записи не должна исчезать в интерфейсе как успешное удаление.
let failureDir = dir.appendingPathComponent("failure")
var failWrites = false
let failing = PersonalCorpus(directory: failureDir, keyProvider: { key }, writer: { data, url in
    if failWrites { throw CocoaError(.fileWriteNoPermission) }
    try data.write(to: url, options: .atomic)
})
expect(failing.add(t1, bundleID: "one"), "исходная запись сохранена")
let failureID = failing.snapshot().records[0].id
failWrites = true
expect(!failing.remove(id: failureID), "ошибка удаления возвращается вызывающему коду")
expect(failing.count == 1 && PersonalCorpus(directory: failureDir, keyProvider: { key }).count == 1, "ошибка удаления сохраняет память и диск")
expect(!failing.removeAll() && failing.count == 1, "ошибка полной очистки сохраняет записи")
// remove(bundleID:)
corpus.remove(bundleID: "com.mail")
expect(corpus.count == 2, "remove(bundleID:)")
expect(PersonalCorpus(directory: dir, keyProvider: { key }).count == 2, "remove сохранён на диск")

corpus.removeAll()
expect(corpus.count == 0, "removeAll")

print(failures == 0 ? "ALL OK" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
