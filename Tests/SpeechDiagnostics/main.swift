import Foundation
import CryptoKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func rejects(_ action: () throws -> Void) {
    do { try action(); fatalError("Ожидалась ошибка") } catch {}
}
let suiteName = "speech-policy-test-" + UUID().uuidString
let isolatedDefaults = UserDefaults(suiteName: suiteName)!
defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
let policy = SpeechCollectionPolicy(defaults: isolatedDefaults, environmentEnabled: { false })
SpeechDiagnostics.collectionPolicy = policy
require(!policy.enabled && policy.captureGeneration() == nil, "Сбор должен быть выключен по умолчанию")
policy.setEnabled(true)
let firstConsent = policy.captureGeneration()!
policy.setEnabled(false)
require(!policy.performIfCurrent(firstConsent, { fatalError("Запись после выключения") }), "Старое согласие не отозвано")
policy.setEnabled(true)
require(!policy.performIfCurrent(firstConsent, { fatalError("Старое согласие после повторного включения") }), "Старая трасса ожила")
policy.setEnabled(false)
let envPolicy = SpeechCollectionPolicy(defaults: isolatedDefaults, environmentEnabled: { true })
require(!envPolicy.enabled, "Явное выключение важнее переменной окружения")
print("PASS: isolated OFF default, deliberate enable, revoke in-flight consent and no stale re-enable")
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

let retentionRoot = root.appendingPathComponent("retention")
try FileManager.default.createDirectory(at: retentionRoot, withIntermediateDirectories: false)
let retentionStore = SpeechDiagnosticsStore(directory: retentionRoot, enabled: true, keyProvider: { key })
let now = Date()
var retainedCandidates: [URL] = []
for index in 0..<205 {
    let candidate = retentionRoot.appendingPathComponent(UUID().uuidString + ".enc")
    try encrypted.write(to: candidate)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-Double(index))], ofItemAtPath: candidate.path)
    retainedCandidates.append(candidate)
}
let unrelated = retentionRoot.appendingPathComponent("notes.txt")
try Data("unrelated".utf8).write(to: unrelated)
let malformedName = retentionRoot.appendingPathComponent("not-a-uuid.enc")
try encrypted.write(to: malformedName)
let linked = retentionRoot.appendingPathComponent(UUID().uuidString + ".enc")
try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: unrelated)
let namedDirectory = retentionRoot.appendingPathComponent(UUID().uuidString + ".enc")
try FileManager.default.createDirectory(at: namedDirectory, withIntermediateDirectories: false)
try retentionStore.prune(now: now)
require(retainedCandidates.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 200, "Лимит записей не соблюдён")
require(FileManager.default.fileExists(atPath: retainedCandidates[0].path), "Удалена новая запись")
require(!FileManager.default.fileExists(atPath: retainedCandidates[204].path), "Не удалена старая лишняя запись")
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86400)], ofItemAtPath: retainedCandidates[0].path)
try retentionStore.prune(now: now)
require(!FileManager.default.fileExists(atPath: retainedCandidates[0].path), "Запись старше 7 дней осталась")
try retentionStore.deleteRecords()
require(!retainedCandidates.contains { FileManager.default.fileExists(atPath: $0.path) }, "Собранные примеры не удалены")
for url in [unrelated, malformedName, linked, namedDirectory] {
    require(FileManager.default.fileExists(atPath: url.path), "Удалён посторонний файл, симлинк или каталог")
}
print("PASS: retention max200/7days, explicit deletion, unrelated files/symlinks/directories preserved")

let envSuiteName = "speech-policy-env-test-" + UUID().uuidString
let envDefaults = UserDefaults(suiteName: envSuiteName)!
defer { envDefaults.removePersistentDomain(forName: envSuiteName) }
let compatibleEnvironment = SpeechCollectionPolicy(defaults: envDefaults, environmentEnabled: { true })
require(compatibleEnvironment.enabled, "Утрачена совместимость с явным opt-in окружения")
compatibleEnvironment.setEnabled(false)
require(!compatibleEnvironment.enabled, "UI не может выключить opt-in окружения")
policy.setEnabled(true)
let inFlight = SpeechDiagnostics.begin(samples: samples, configuration: [:])!
let inFlightGeneration = inFlight.collectionGeneration!
policy.setEnabled(false)
policy.setEnabled(true)
require(!policy.performIfCurrent(inFlightGeneration, { fatalError("Сохранена отозванная трасса") }), "Runtime сохранил устаревшее согласие")
policy.setEnabled(false)
print("PASS: environment compatibility, explicit UI OFF precedence and runtime begin consent revocation")

let blockedRoot = root.appendingPathComponent("blocked-key-provider")
let providerEntered = DispatchSemaphore(value: 0)
let releaseProvider = DispatchSemaphore(value: 0)
let savedFinished = DispatchSemaphore(value: 0)
let offFinished = DispatchSemaphore(value: 0)
let blockedStateLock = NSLock()
var blockedSaveFailed = false
var blockedSaveResult: URL?
policy.setEnabled(true)
let blockedGeneration = policy.captureGeneration()!
let blockedSnapshot = SpeechDiagnosticTrace(samples: [0.25], configuration: [:]).snapshot(outcome: "test")
DispatchQueue.global().async {
    let blockedStore = SpeechDiagnosticsStore(directory: blockedRoot, enabled: true, keyProvider: {
        providerEntered.signal()
        releaseProvider.wait()
        return key
    })
    do {
        let result = try blockedStore.save(blockedSnapshot, authorizePublication: { publish in
            try policy.performIfCurrent(blockedGeneration, publish)
        })
        blockedStateLock.lock(); blockedSaveResult = result; blockedStateLock.unlock()
    } catch { blockedStateLock.lock(); blockedSaveFailed = true; blockedStateLock.unlock() }
    savedFinished.signal()
}
require(providerEntered.wait(timeout: .now() + 5) == .success, "Синтетический провайдер не запущен")
DispatchQueue.global().async {
    policy.setEnabled(false)
    require(!policy.enabled, "Выключение не применено")
    offFinished.signal()
}
let responsiveOff = offFinished.wait(timeout: .now() + 2) == .success
releaseProvider.signal()
require(savedFinished.wait(timeout: .now() + 5) == .success, "Сохранение зависло после освобождения провайдера")
require(responsiveOff, "Выключение ждёт Keychain или диск")
blockedStateLock.lock()
let revokedSaveClean = !blockedSaveFailed && blockedSaveResult == nil
blockedStateLock.unlock()
require(revokedSaveClean, "Отозванное согласие опубликовало запись или вызвало ошибку")
let leftovers = try FileManager.default.contentsOfDirectory(atPath: blockedRoot.path)
require(leftovers.isEmpty, "После отмены остался финальный или временный файл")
print("PASS: OFF remains responsive during blocked key provider, revoked publication and temporary-file cleanup")
