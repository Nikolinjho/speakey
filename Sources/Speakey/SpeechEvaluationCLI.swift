import Foundation
import CryptoKit

/// Локальный повтор через тот же WhisperBridge, с явным отсутствием личного словаря.
/// Это ASR + удаление эха затравки, без VoiceController и дальнейших исправлений текста.
enum SpeechEvaluationCLI {
    enum Failure: Error { case modelUnavailable, inferenceFailed }

    static func run(arguments: [String], parakeetLoad: SpeechParakeetEvaluation.Loader = SpeechParakeetEvaluation.loadLocal) async -> Int32 {
        do {
            let options = try SpeechCLIArguments.parse(arguments)
            if options.command == "export" {
                try SpeechDiagnosticsExport.export(encrypted: options.input, output: options.output,
                                                   keyProvider: SpeechDiagnostics.existingKeyForExport)
            } else if options.engine == "parakeet" {
                try await transcribeParakeet(options, load: parakeetLoad)
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
            "schema": 1, "engine": "whisper", "hypothesis": hypothesis,
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

    private static func transcribeParakeet(_ options: SpeechCLIArguments, load: SpeechParakeetEvaluation.Loader) async throws {
        guard !FileManager.default.fileExists(atPath: options.output.path) else { throw SpeechDiagnosticsExport.Failure.outputExists }
        guard let directory = options.model, let language = options.language else { throw Failure.modelUnavailable }
        let audioFile = try options.input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard audioFile.isRegularFile == true, let fileSize = audioFile.fileSize,
              fileSize <= SpeechFloatWAV.maximumByteCount else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let input = try Data(contentsOf: options.input)
        let samples = try SpeechFloatWAV.read(input)
        let replay = try await SpeechParakeetEvaluation.transcribe(samples: samples, language: language, directory: directory, load: load)
        var config = replay.configuration
        config["engine"] = "parakeet"
        config["model_version"] = "v3"
        config["encoder_precision"] = "int8"
        config["prompt_sha256"] = digest(Data())
        config["recognition_hint"] = "disabled_explicitly"
        config["language_semantics"] = "script_filter_ru_en_auto_disabled"
        config["parameter_base"] = "linked_FluidAudio_ASRConfig_defaults_melChunkContext_false"
        config["production_configuration_equivalent"] = "false_not_captured"
        config["model_manifest_format"] = "relative-ascii-path-sha256-json-v1"
        config["model_manifest_scope"] = "loaded_v3_int8_components"
        config["loaded_components"] = SpeechParakeetEvaluation.components.joined(separator: ",")
        let configData = try canonicalConfiguration(config)
        let document: [String: Any] = [
            "schema": 1, "engine": "parakeet", "model_version": "v3",
            "hypothesis": replay.hypothesis, "raw_hypothesis": replay.hypothesis,
            "model_sha256": replay.modelSHA256, "language": language,
            "elapsed_seconds": replay.elapsedSeconds, "model_load_seconds": replay.loadSeconds,
            "sample_count": samples.count, "sample_rate": 16000, "input_wav_sha256": digest(input),
            "scope": "parakeet_v3_vendor_result_no_dictionary_no_output_options",
            "config": config, "config_sha256": digest(configData), "config_sha256_format": "sorted-compact-utf8-v1"
        ]
        try SpeechDiagnosticsExport.writeNew(try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), to: options.output)
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
