import Foundation
import CryptoKit
import Darwin

// Дубль только транспортного контракта: настоящая модель не загружается.
final class WhisperBridge {
    static var calls = 0
    static var fail = false
    init?(modelPath: String, recognitionHint: @escaping () -> String?) {
        precondition(recognitionHint() == nil, "CLI отключает личный словарь")
    }
    func transcribe(samples: [Float], language: String, diagnostics: SpeechDiagnosticTrace?) -> String {
        Self.calls += 1
        diagnostics?.record("whisper_configuration", text: "private prompt sentinel", metadata: ["strategy": "greedy"])
        diagnostics?.record("whisper_result", metadata: ["returnCode": Self.fail ? "-1" : "0"])
        diagnostics?.record("whisper_raw", text: "Сырой результат")
        return "Результат"
    }
}

func check(_ condition: Bool, _ name: String) {
    if !condition { fatalError(name) }
}
func rejects(_ name: String, _ body: () throws -> Void) {
    do { try body(); fatalError(name) } catch { }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-export-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: root) }
let samples = [Float(bitPattern: 0), Float(bitPattern: 0x80000000), 0.25, -0.125, 1, -1]
let trace = SpeechDiagnosticTrace(samples: samples, configuration: ["engine": "synthetic"])
trace.record("whisper_raw", text: "Это гипотеза, не эталон.")
let snapshot = trace.snapshot(outcome: "success")
let key = Data(repeating: 7, count: 32)
let store = SpeechDiagnosticsStore(directory: root.appendingPathComponent("encrypted"), enabled: true, keyProvider: { key })
let encrypted = try store.save(snapshot)!
let output = root.appendingPathComponent("export")
try SpeechDiagnosticsExport.export(encrypted: encrypted, output: output, keyProvider: { key })
let wav = try Data(contentsOf: output.appendingPathComponent("audio.wav"))
check(wav.suffix(snapshot.pcmFloat32LE.count) == snapshot.pcmFloat32LE, "Точные биты PCM сохранены")
let decoded = try SpeechFloatWAV.read(wav)
check(decoded.map(\.bitPattern) == samples.map(\.bitPattern), "WAV читается без потери битов")
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("manifest.jsonl"))) as! [String: Any]
check(manifest["reference"] as? String == "", "Гипотеза не становится эталоном")
check(manifest["reference_confirmed"] as? Bool == false, "Нужна ручная сверка")
for name in ["audio.wav", "trace.json", "manifest.jsonl"] {
    let attrs = try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(name).path)
    check((attrs[.posixPermissions] as! NSNumber).intValue == 0o600, "Права файла 600")
}
let directoryAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
check((directoryAttributes[.posixPermissions] as! NSNumber).intValue == 0o700, "Права каталога 700")
rejects("Запрет перезаписи") { try SpeechDiagnosticsExport.export(encrypted: encrypted, output: output, keyProvider: { key }) }
let brokenOutput = root.appendingPathComponent("broken")
rejects("Неверный ключ") { try SpeechDiagnosticsExport.export(encrypted: encrypted, output: brokenOutput, keyProvider: { Data(repeating: 8, count: 32) }) }
check(!FileManager.default.fileExists(atPath: brokenOutput.path), "Нет частичного экспорта")
rejects("Нет автоматического ключа при экспорте") { _ = try SpeechDiagnosticsKey.requireExisting(read: { nil }) }
rejects("Обрезанный WAV") { _ = try SpeechFloatWAV.read(wav.dropLast()) }
var integerWav = wav
integerWav[20] = 99
rejects("Неизвестный WAV-кодек") { _ = try SpeechFloatWAV.read(integerWav) }
let parsed = try SpeechCLIArguments.parse(["transcribe", "--input", "a.wav", "--model", "m.bin", "--language", "ru", "--output", "o.json"])
check(parsed.command == "transcribe" && parsed.language == "ru", "CLI разбирает явные аргументы")
rejects("Не принимает неизвестные аргументы") { _ = try SpeechCLIArguments.parse(["export", "--input", "a", "--output", "b", "--key", "secret"]) }
rejects("Не принимает повторные аргументы") { _ = try SpeechCLIArguments.parse(["export", "--input", "a", "--input", "b", "--output", "c"]) }
print("PASS: synthetic encrypted export, exact float32 WAV, permissions, no overwrite/partial output, read-only key and CLI validation")

let fakeModel = root.appendingPathComponent("synthetic-model.bin")
try Data("synthetic model, not inference".utf8).write(to: fakeModel)
let replay = root.appendingPathComponent("replay.json")
let replayArgs = ["transcribe", "--input", output.appendingPathComponent("audio.wav").path,
                  "--model", fakeModel.path, "--language", "auto", "--output", replay.path]
check(await SpeechEvaluationCLI.run(arguments: replayArgs) == 0, "CLI синтетически вызывает мост")
let replayData = try Data(contentsOf: replay)
let replayDoc = try JSONSerialization.jsonObject(with: replayData) as! [String: Any]
check(replayDoc["hypothesis"] as? String == "Результат", "Итоговая гипотеза")
check(replayDoc["raw_hypothesis"] as? String == "Сырой результат", "Сырой вывод отдельно")
check(replayDoc["model_sha256"] as? String == SHA256.hash(data: Data("synthetic model, not inference".utf8)).map { String(format: "%02x", $0) }.joined(), "Хеш локальной модели")
check(!String(decoding: replayData, as: UTF8.self).contains("private prompt sentinel"), "Промпт не раскрывается в метаданных")
check(await SpeechEvaluationCLI.run(arguments: replayArgs) == 1 && WhisperBridge.calls == 1, "Существующий вывод отклоняется до распознавания")
WhisperBridge.fail = true
let failedReplay = root.appendingPathComponent("failed.json")
var failedArgs = replayArgs
failedArgs[failedArgs.count - 1] = failedReplay.path
check(await SpeechEvaluationCLI.run(arguments: failedArgs) == 1, "Ошибка whisper не становится пустой гипотезой")
check(!FileManager.default.fileExists(atPath: failedReplay.path), "Нет частичного результата при ошибке распознавания")
print("PASS: synthetic CLI bridge contract, local model hash, raw/final hypotheses, prompt hash privacy and inference failure (stub, not model inference)")

func integerWAV(bits: Int, payload: [UInt8]) -> Data {
    var wav = try! SpeechFloatWAV.encode(pcm: Data(repeating: 0, count: 4))
    wav.removeSubrange(44..<wav.count)
    wav.append(contentsOf: payload)
    if payload.count % 2 == 1 { wav.append(0) }
    func set(_ value: UInt32, at offset: Int, bytes: Int) {
        for index in 0..<bytes { wav[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
    set(UInt32(wav.count - 8), at: 4, bytes: 4)
    set(1, at: 20, bytes: 2)
    set(UInt32(16000 * bits / 8), at: 28, bytes: 4)
    set(UInt32(bits / 8), at: 32, bytes: 2)
    set(UInt32(bits), at: 34, bytes: 2)
    set(UInt32(payload.count), at: 40, bytes: 4)
    return wav
}
for (bits, payload, expected): (Int, [UInt8], [Float]) in [
    (8, [0, 128, 255], [-1, 0, 127.0 / 128]),
    (16, [0, 128, 0, 0, 255, 127], [-1, 0, 32767.0 / 32768]),
    (24, [0, 0, 128, 255, 255, 255, 0, 0, 0, 255, 255, 127], [-1, -1.0 / 8388608, 0, 8388607.0 / 8388608]),
    (32, [0, 0, 0, 128, 0, 0, 0, 0, 255, 255, 255, 127], [-1, 0, 1])
] {
    let converted = try SpeechFloatWAV.read(integerWAV(bits: bits, payload: payload))
    check(converted == expected, "Нормирование PCM\(bits) с сохранением знака")
}
print("PASS: WAV PCM8/16/24/32 normalized conversion and float32 bit preservation")

// Повреждённый fmt отклоняется до чтения его полей.
var emptyFormat = Data("RIFF".utf8)
emptyFormat.append(contentsOf: [12, 0, 0, 0])
emptyFormat.append(Data("WAVEfmt ".utf8))
emptyFormat.append(contentsOf: [0, 0, 0, 0])
rejects("Пустой fmt не обращается за пределы буфера") { _ = try SpeechFloatWAV.read(emptyFormat) }
for length in 0..<wav.count {
    rejects("Обрезанный WAV длины \(length)") { _ = try SpeechFloatWAV.read(Data(wav.prefix(length))) }
}
print("PASS: all truncation boundaries and empty format rejection")

let replayConfig = replayDoc["config"] as! [String: String]
let canonicalConfig = try SpeechEvaluationCLI.canonicalConfiguration(replayConfig)
let configHash = SHA256.hash(data: canonicalConfig).map { String(format: "%02x", $0) }.joined()
check(replayDoc["config_sha256"] as? String == configHash, "Хеш канонической конфигурации")
for malformedSamples: [Float] in [[], [Float.nan], [Float.infinity], [-Float.infinity]] {
    let malformedTrace = SpeechDiagnosticTrace(samples: malformedSamples, configuration: [:])
    let malformedSnapshot = malformedTrace.snapshot(outcome: "synthetic")
    let malformedEncrypted = try store.save(malformedSnapshot)!
    let malformedOutput = root.appendingPathComponent("invalid-" + UUID().uuidString)
    rejects("Пустой и неконечный PCM не экспортируется") {
        try SpeechDiagnosticsExport.export(encrypted: malformedEncrypted, output: malformedOutput, keyProvider: { key })
    }
    check(!FileManager.default.fileExists(atPath: malformedOutput.path), "Невалидный PCM не создаёт каталог")
}
for size in 0..<16 {
    var shortFormat = Data("RIFF".utf8)
    let bodySize = 12 + size + size % 2
    shortFormat.append(contentsOf: [UInt8(bodySize), 0, 0, 0])
    shortFormat.append(Data("WAVEfmt ".utf8))
    shortFormat.append(contentsOf: [UInt8(size), 0, 0, 0])
    shortFormat.append(Data(repeating: 0, count: size + size % 2))
    rejects("Короткий fmt длины \(size)") { _ = try SpeechFloatWAV.read(shortFormat) }
}
print("PASS: configuration hash, empty/nonfinite PCM export rejection, terminal fmt lengths 0...15")

var oversizedChunk = wav
for index in 40..<44 { oversizedChunk[index] = 255 }
rejects("Огромный объявленный размер не выделяет память по заголовку") { _ = try SpeechFloatWAV.read(oversizedChunk) }
let oversizedFile = root.appendingPathComponent("oversized.wav")
try Data().write(to: oversizedFile)
let oversizedHandle = try FileHandle(forWritingTo: oversizedFile)
try oversizedHandle.truncate(atOffset: UInt64(SpeechFloatWAV.maximumByteCount + 1))
try oversizedHandle.close()
var oversizedArgs = replayArgs
oversizedArgs[2] = oversizedFile.path
oversizedArgs[oversizedArgs.count - 1] = root.appendingPathComponent("oversized-result.json").path
let callsBeforeOversized = WhisperBridge.calls
check(await SpeechEvaluationCLI.run(arguments: oversizedArgs) == 1 && WhisperBridge.calls == callsBeforeOversized,
      "Большой разреженный WAV отклоняется до загрузки модели и чтения файла")
check(replayDoc["config_sha256_format"] as? String == "sorted-compact-utf8-v1", "Формат хеша конфигурации")
print("PASS: bounded WAV file size before read/model load and oversized chunk rejection")

let mixedCaseConfig = ["promptLanguage": "ru", "prompt_sha256": "abc", "noContext": "true", "no_speech": "0.6"]
let mixedCaseCanonical = try SpeechEvaluationCLI.canonicalConfiguration(mixedCaseConfig)
check(String(decoding: mixedCaseCanonical, as: UTF8.self) == #"{"noContext":"true","no_speech":"0.6","promptLanguage":"ru","prompt_sha256":"abc"}"#,
      "Ключи конфигурации сортируются лексикографически с учётом регистра как в Python")
check(SHA256.hash(data: mixedCaseCanonical).map { String(format: "%02x", $0) }.joined() == "be5c7af108b8fd7c05caf0c8b7739eef0bb8035341030be24b333079812c0d36", "Совпадает с контрольным SHA256 Python json.dumps")
print("PASS: mixed-case and underscore configuration canonicalization matches Python SHA256")

let parakeetOptions = try SpeechCLIArguments.parse(["transcribe", "--engine", "parakeet", "--input", "a.wav", "--model", "local-dir", "--language", "ru", "--output", "p.json"])
check(parakeetOptions.engine == "parakeet", "Явный локальный движок Parakeet")
check(parsed.engine == "whisper", "Старые вызовы по умолчанию используют Whisper")
rejects("Неизвестный движок") {
    _ = try SpeechCLIArguments.parse(["transcribe", "--engine", "remote", "--input", "a.wav", "--model", "m", "--language", "ru", "--output", "p.json"])
}

let parakeetDirectory = root.appendingPathComponent("parakeet-tdt-0.6b-v3")
try FileManager.default.createDirectory(at: parakeetDirectory, withIntermediateDirectories: false)
for component in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
    let bundle = parakeetDirectory.appendingPathComponent(component)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
    try Data(component.utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
}
try Data("{}".utf8).write(to: parakeetDirectory.appendingPathComponent("parakeet_vocab.json"))
let firstManifest = try SpeechParakeetEvaluation.modelManifest(directory: parakeetDirectory)
try Data("unused".utf8).write(to: parakeetDirectory.appendingPathComponent("unused.txt"))
check(try SpeechParakeetEvaluation.modelManifest(directory: parakeetDirectory) == firstManifest, "Хеш учитывает только загружаемые компоненты")
let link = parakeetDirectory.appendingPathComponent("unused-link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: encrypted)
rejects("Симлинки запрещены даже вне загружаемых компонентов") { _ = try SpeechParakeetEvaluation.modelManifest(directory: parakeetDirectory) }
try FileManager.default.removeItem(at: link)
let parakeetReplay = try await SpeechParakeetEvaluation.transcribe(samples: samples, language: "ru", directory: parakeetDirectory, load: { _ in
    SpeechParakeetEvaluation.Loaded(configuration: ["synthetic": "true"], transcribe: { input, language in
        check(input.map(\.bitPattern) == samples.map(\.bitPattern), "Parakeet получает точный Float32")
        check(language == "ru", "Язык передан фильтру письменности")
        return "Сырой результат Parakeet"
    })
})
check(parakeetReplay.hypothesis == "Сырой результат Parakeet", "Сырой результат без фильтров приложения")
var mutationRejected = false
var mutatedDecodeCalled = false
do {
    _ = try await SpeechParakeetEvaluation.transcribe(samples: samples, language: "auto", directory: parakeetDirectory, load: { directory in
        try Data("changed".utf8).write(to: directory.appendingPathComponent("parakeet_vocab.json"))
        return SpeechParakeetEvaluation.Loaded(configuration: [:], transcribe: { _, _ in
            mutatedDecodeCalled = true
            return "wrong"
        })
    })
} catch { mutationRejected = true }
check(mutationRejected && !mutatedDecodeCalled, "Изменение модели при загрузке останавливает декодирование")
print("PASS: Parakeet loaded-component manifest, no symlinks, exact audio/language and model mutation rejection (synthetic loader)")

try Data("{}".utf8).write(to: parakeetDirectory.appendingPathComponent("parakeet_vocab.json"))
let parakeetOutput = root.appendingPathComponent("parakeet-result.json")
let parakeetArgs = ["transcribe", "--engine", "parakeet", "--input", output.appendingPathComponent("audio.wav").path,
                   "--model", parakeetDirectory.path, "--language", "auto", "--output", parakeetOutput.path]
let parakeetStatus = await SpeechEvaluationCLI.run(arguments: parakeetArgs, parakeetLoad: { _ in
    SpeechParakeetEvaluation.Loaded(configuration: ["melChunkContext": "false"], transcribe: { _, language in
        check(language == "auto", "CLI сохраняет режим отключённого фильтра")
        return "Текст локального Parakeet"
    })
})
check(parakeetStatus == 0, "CLI умеет локальный Parakeet без микрофона")
let parakeetDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: parakeetOutput)) as! [String: Any]
check(parakeetDocument["engine"] as? String == "parakeet", "Движок записан явно")
check(parakeetDocument["raw_hypothesis"] as? String == parakeetDocument["hypothesis"] as? String, "Сырой результат без скрытых исправлений")
check((parakeetDocument["config"] as! [String: String])["prompt_sha256"] == SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined(), "У Parakeet нет затравки")
print("PASS: async Parakeet CLI output/config contract (synthetic loader)")

check(SHA256.hash(data: firstManifest).map { String(format: "%02x", $0) }.joined() == "1f816d3f3dcc89160e48b332b846718195a02848c20c295f82ab8240593328f8", "Манифест модели совпадает с эталоном Python")
rejects("Иное имя каталога не перенаправляет загрузку к соседней модели") { _ = try SpeechParakeetEvaluation.modelManifest(directory: root) }
let special = parakeetDirectory.appendingPathComponent("unused.fifo")
check(mkfifo(special.path, 0o600) == 0, "Создан синтетический FIFO")
rejects("Специальные файлы запрещены даже вне компонентов") { _ = try SpeechParakeetEvaluation.modelManifest(directory: parakeetDirectory) }
try FileManager.default.removeItem(at: special)
let nonASCII = parakeetDirectory.appendingPathComponent("не-ASCII")
try Data().write(to: nonASCII)
rejects("Не-ASCII пути не имеют неоднозначного порядка сортировки") { _ = try SpeechParakeetEvaluation.modelManifest(directory: parakeetDirectory) }
try FileManager.default.removeItem(at: nonASCII)
var inferenceMutationRejected = false
do {
    _ = try await SpeechParakeetEvaluation.transcribe(samples: samples, language: "en", directory: parakeetDirectory, load: { directory in
        SpeechParakeetEvaluation.Loaded(configuration: [:], transcribe: { _, _ in
            try Data("changed-during-inference".utf8).write(to: directory.appendingPathComponent("parakeet_vocab.json"))
            return "unverified"
        })
    })
} catch { inferenceMutationRejected = true }
check(inferenceMutationRejected, "Изменение модели во время декодирования не публикуется")
try Data("{}".utf8).write(to: parakeetDirectory.appendingPathComponent("parakeet_vocab.json"))
var unavailableArgs = parakeetArgs
unavailableArgs[unavailableArgs.count - 1] = root.appendingPathComponent("unavailable-parakeet.json").path
let whisperCalls = WhisperBridge.calls
let unavailableStatus = await SpeechEvaluationCLI.run(arguments: unavailableArgs)
check(unavailableStatus == 1 && WhisperBridge.calls == whisperCalls, "Недоступный Parakeet не заменяется Whisper")
check(!FileManager.default.fileExists(atPath: unavailableArgs.last!), "При отказе нет частичного результата")
let missing = parakeetDirectory.appendingPathComponent("Decoder.mlmodelc/coremldata.bin")
try FileManager.default.removeItem(at: missing)
rejects("Неполная модель отклоняется локально") { _ = try SpeechParakeetEvaluation.modelManifest(directory: parakeetDirectory) }
print("PASS: Python model manifest parity, wrong directory, special/nonASCII files, incomplete model, inference mutation and no fallback")
check(SpeechParakeetEvaluation.directoryName == "parakeet-tdt-0.6b-v3", "Каталог FluidAudio использует folderName без суффикса coreml")

let obsoleteDirectory = root.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
try FileManager.default.createDirectory(at: obsoleteDirectory, withIntermediateDirectories: false)
rejects("Имя репозитория не подменяет реальный folderName загрузчика") { _ = try SpeechParakeetEvaluation.modelManifest(directory: obsoleteDirectory) }
print("PASS: linked FluidAudio cache basename contract and obsolete repo-name rejection")
