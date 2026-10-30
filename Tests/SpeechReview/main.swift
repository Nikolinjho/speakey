import Foundation
import CryptoKit
import Darwin

func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { fatalError(message) }
}
func rejects(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError(message) } catch { }
}
let requested = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : FileManager.default.temporaryDirectory.appendingPathComponent("speech-review-" + UUID().uuidString)
let physicalParent = realpath(requested.deletingLastPathComponent().path, nil)!
defer { free(physicalParent) }
let root = URL(fileURLWithPath: String(cString: physicalParent)).appendingPathComponent(requested.lastPathComponent)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { if CommandLine.arguments.count == 1 { try? FileManager.default.removeItem(at: root) } }
let key = Data(repeating: 7, count: 32)
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
