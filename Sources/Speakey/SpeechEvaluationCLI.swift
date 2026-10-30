import Foundation
import CryptoKit

/// Локальный повтор через тот же WhisperBridge, с явным отсутствием личного словаря.
/// Это ASR + удаление эха затравки, без VoiceController и дальнейших исправлений текста.
enum SpeechEvaluationCLI {
    enum Failure: Error { case modelUnavailable, inferenceFailed }

    static func run(arguments: [String]) -> Int32 {
        do {
            let options = try SpeechCLIArguments.parse(arguments)
            if options.command == "export" {
                try SpeechDiagnosticsExport.export(encrypted: options.input, output: options.output,
                                                   keyProvider: SpeechDiagnostics.existingKeyForExport)
            } else {
                try transcribe(options)
            }
            return 0
        } catch {
            // Ошибка не печатает аргументы, содержимое записи, подсказку или путь к личным файлам.
            fputs("Speakey speech CLI failed (invalid input, unavailable local resource, or existing output).\n", stderr)
            return 1
        }
    }

    private static func transcribe(_ options: SpeechCLIArguments) throws {
        guard !FileManager.default.fileExists(atPath: options.output.path) else { throw SpeechDiagnosticsExport.Failure.outputExists }
        guard let model = options.model, let language = options.language,
              try model.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw Failure.modelUnavailable }
        let audioFile = try options.input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard audioFile.isRegularFile == true, let fileSize = audioFile.fileSize,
              fileSize <= SpeechFloatWAV.maximumByteCount else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let input = try Data(contentsOf: options.input)
        let samples = try SpeechFloatWAV.read(input)
        guard samples.count <= Int(Int32.max) else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let modelHash = try sha256(file: model)
        let loadStart = ProcessInfo.processInfo.systemUptime
        // В CLI не читаем VoiceDictionary.shared и AppSettings.shared, не меняем UserDefaults.
        guard let bridge = WhisperBridge(modelPath: model.path, recognitionHint: { nil }) else { throw Failure.modelUnavailable }
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        let trace = SpeechDiagnosticTrace(samples: samples, configuration: ["scope": "isolated_whisper_bridge_no_dictionary"])
        let started = ProcessInfo.processInfo.systemUptime
        let hypothesis = bridge.transcribe(samples: samples, language: language, diagnostics: trace)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let snapshot = trace.snapshot(outcome: "replay")
        guard let result = snapshot.events.last(where: { $0.stage == "whisper_result" }),
              result.metadata["returnCode"] == "0" else { throw Failure.inferenceFailed }
        let configuration = snapshot.events.last(where: { $0.stage == "whisper_configuration" })
        var config = configuration?.metadata ?? [:]
        config["prompt_sha256"] = digest(Data((configuration?.text ?? "").utf8))
        config["recognition_hint"] = "disabled_explicitly"
        config["gpu"] = "true"
        config["parameter_base"] = "linked_whisper_full_default_params_greedy_with_bridge_overrides"
        config["production_configuration_equivalent"] = "false_not_captured"
        // Канонизация: UTF-8 JSON, сортировка ключей, без пробелов и экранирования слешей.
        let configData = try canonicalConfiguration(config)
        let document: [String: Any] = [
            "schema": 1, "hypothesis": hypothesis,
            "raw_hypothesis": snapshot.events.last(where: { $0.stage == "whisper_raw" })?.text ?? "",
            "model_sha256": modelHash, "language": language,
            "elapsed_seconds": elapsed, "model_load_seconds": loadSeconds,
            "sample_count": samples.count, "sample_rate": 16000,
            "input_wav_sha256": digest(input),
            "scope": "whisper_bridge_echo_cleaned_no_dictionary_no_output_options",
            "config": config, "config_sha256": digest(configData),
            "config_sha256_format": "sorted-compact-utf8-v1"
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try SpeechDiagnosticsExport.writeNew(data, to: options.output)
    }

    static func canonicalConfiguration(_ config: [String: String]) throws -> Data {
        // Foundation .sortedKeys сравнивает без учёта регистра, Python sort_keys — с учётом.
        // Ключи конфигурации заданы в коде и ограничены ASCII для общего порядка сортировки.
        guard config.keys.allSatisfy({ $0.utf8.allSatisfy { $0 < 128 } }) else {
            throw SpeechDiagnosticsExport.Failure.invalidArguments
        }
        var data = Data("{".utf8)
        for (index, key) in config.keys.sorted().enumerated() {
            if index > 0 { data.append(0x2c) }
            data.append(try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            data.append(0x3a)
            data.append(try JSONSerialization.data(withJSONObject: config[key]!, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
        }
        data.append(0x7d)
        return data
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
