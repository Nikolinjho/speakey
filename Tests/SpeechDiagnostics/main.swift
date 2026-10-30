import Foundation
import CryptoKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func rejects(_ action: () throws -> Void) {
    do { try action(); fatalError("Ожидалась ошибка") } catch {}
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-diagnostics-test-\(UUID())")
defer { try? FileManager.default.removeItem(at: root) }
let key = Data(repeating: 42, count: 32)
let samples = [Float(bitPattern: 0x80000000), 0.125, -0.25, Float(bitPattern: 0x7fc00001)]
let trace = SpeechDiagnosticTrace(samples: samples, configuration: ["engine": "synthetic"])
trace.record("raw_asr", text: "Привет, мир!")
let snapshot = trace.snapshot(outcome: "synthetic")
let disabled = SpeechDiagnosticsStore(directory: root, enabled: false, keyProvider: { fatalError("Ключ запрошен при выключенной диагностике") })
let disabledResult = try disabled.save(snapshot)
require(disabledResult == nil, "Выключенная диагностика сохраняет данные")
require(!FileManager.default.fileExists(atPath: root.path), "Выключенная диагностика создала каталог")
let store = SpeechDiagnosticsStore(directory: root, enabled: true, keyProvider: { key })
let file = try store.save(snapshot)!
let encrypted = try Data(contentsOf: file)
require(encrypted.range(of: Data("Привет".utf8)) == nil, "Открытый текст попал на диск")
let decoded = try store.read(file)
require(decoded.pcmFloat32LE == Data([0, 0, 0, 128, 0, 0, 0, 62, 0, 0, 128, 190, 1, 0, 192, 127]), "Биты Float32 изменились")
require(decoded.id == snapshot.id && decoded.events.first?.text == "Привет, мир!", "Трасса изменилась")
require(decoded.sampleRate == 16000 && decoded.channels == 1, "Формат изменился")
let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
require(permissions.intValue == 0o600, "Файл доступен другим пользователям")
let missing = SpeechDiagnosticsStore(directory: root.appendingPathComponent("missing"), enabled: true, keyProvider: { throw NSError(domain: "test", code: 1) })
rejects { _ = try missing.save(snapshot) }
require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path), "Ошибка ключа создала каталог")
let invalid = SpeechDiagnosticsStore(directory: root, enabled: true, keyProvider: { Data(repeating: 0, count: 31) })
rejects { _ = try invalid.save(snapshot) }
let wrong = SpeechDiagnosticsStore(directory: root, enabled: true, keyProvider: { Data(repeating: 0, count: 32) })
rejects { _ = try wrong.read(file) }
let blocker = root.appendingPathComponent("not-a-directory")
try Data([1]).write(to: blocker)
let blocked = SpeechDiagnosticsStore(directory: blocker, enabled: true, keyProvider: { key })
rejects { _ = try blocked.save(snapshot) }
var tampered = encrypted
tampered[tampered.count - 1] ^= 1
let corrupt = root.appendingPathComponent("corrupt.enc")
try tampered.write(to: corrupt)
rejects { _ = try store.read(corrupt) }
require(trace.snapshot(outcome: "next").events.count == 1, "Снимок изменил трассу")
print("PASS: disabled, encrypted lossless roundtrip, permissions, key failure, invalid/wrong key, disk failure, tamper rejection")
rejects { _ = try store.save(snapshot) }
let unchanged = try Data(contentsOf: file)
require(unchanged == encrypted, "Повторная запись затёрла исходник")
rejects {
    _ = try SpeechDiagnosticsKey.resolve(read: { nil }, create: { _ in fatalError("Нельзя перевыпускать ключ существующих записей") }, hasRecords: { true })
}
rejects {
    var reads = 0
    _ = try SpeechDiagnosticsKey.resolve(read: { reads += 1; return reads == 1 ? nil : Data(repeating: 1, count: 32) }, create: { _ in true }, hasRecords: { false })
}
var generatedKey: Data?
let verifiedKey = try SpeechDiagnosticsKey.resolve(read: { generatedKey }, create: { generatedKey = $0; return true }, hasRecords: { false })
require(verifiedKey == generatedKey && verifiedKey.count == 32, "Новый ключ не проверен чтением")
print("PASS: no overwrite, missing-key fail closed, verified key creation")
require(!SpeechDiagnostics.enabled, "Тест должен запускаться без opt-in")
require(SpeechDiagnostics.begin(samples: samples, configuration: [:]) == nil, "Без opt-in создана трасса")
let concurrent = SpeechDiagnosticTrace(samples: [], configuration: [:])
DispatchQueue.concurrentPerform(iterations: 100) { i in concurrent.record("synthetic", text: String(i)) }
let independent = SpeechDiagnosticTrace(samples: [], configuration: [:])
require(concurrent.snapshot(outcome: "test").events.count == 100, "Потеряны конкурентные события")
require(independent.id != concurrent.id && independent.snapshot(outcome: "test").events.isEmpty, "Диктовки смешались")
print("PASS: runtime off by default, concurrent events, independent dictation IDs")
let timedOut = SpeechDiagnosticTrace(samples: samples, configuration: [:])
timedOut.record("decode_requested")
let timeoutRecord = timedOut.finalize(outcome: "timeout")
require(timeoutRecord?.outcome == "timeout", "Таймаут не завершил трассу")
require(timeoutRecord?.pcmFloat32LE == snapshot.pcmFloat32LE, "Таймаут потерял исходный звук")
timedOut.record("late_result", text: "Поздний текст")
require(timedOut.finalize(outcome: "late_result_discarded") == nil, "Поздний результат повторно завершил трассу")
require(timedOut.snapshot(outcome: "inspection").events.count == 1, "Поздний результат изменил закрытую трассу")
let finishing = SpeechDiagnosticTrace(samples: [], configuration: [:])
let finishLock = NSLock()
var winners = 0
DispatchQueue.concurrentPerform(iterations: 100) { _ in
    if finishing.finalize(outcome: "test") != nil {
        finishLock.lock(); winners += 1; finishLock.unlock()
    }
}
require(winners == 1, "Конкурентное завершение создало несколько записей")
print("PASS: timeout retains input, late result cannot overwrite, concurrent finalization is one-shot")
