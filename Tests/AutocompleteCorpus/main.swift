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

// remove(bundleID:)
corpus.remove(bundleID: "com.mail")
expect(corpus.count == 2, "remove(bundleID:)")
expect(PersonalCorpus(directory: dir, keyProvider: { key }).count == 2, "remove сохранён на диск")

corpus.removeAll()
expect(corpus.count == 0, "removeAll")

print(failures == 0 ? "ALL OK" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
