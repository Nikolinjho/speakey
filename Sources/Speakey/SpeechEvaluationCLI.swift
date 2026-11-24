import Foundation
import CryptoKit

/// Локальный повтор через тот же WhisperBridge, с явным отсутствием личного словаря.
/// Это ASR + удаление эха затравки, без VoiceController и дальнейших исправлений текста.
enum SpeechEvaluationCLI {
    enum Failure: Error { case modelUnavailable, inferenceFailed, corpusUnavailable, outputInRepository }

    static func run(arguments: [String], parakeetLoad: SpeechParakeetEvaluation.Loader = SpeechParakeetEvaluation.loadLocal) async -> Int32 {
        do {
            let options = try SpeechCLIArguments.parse(arguments)
            if options.command == "export" {
                try SpeechDiagnosticsExport.export(encrypted: try options.requireInput(), output: options.output,
                                                   keyProvider: SpeechDiagnostics.existingKeyForExport)
            } else if options.command == "vocabulary" {
                try exportVocabulary(to: options.output)
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
        let inputURL = try options.requireInput()
        let audioFile = try inputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard audioFile.isRegularFile == true, let fileSize = audioFile.fileSize,
              fileSize <= SpeechFloatWAV.maximumByteCount else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let input = try Data(contentsOf: inputURL)
        let samples = try SpeechFloatWAV.read(input)
        guard samples.count <= Int(Int32.max) else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let modelHash = try sha256(file: model)
        let loadStart = ProcessInfo.processInfo.systemUptime
        // В CLI не читаем AppSettings.shared, не меняем UserDefaults. Словарь диктовки читаем только
        // при SPEAKEY_SPEECH_HINT=1 (замер затравки); по умолчанию затравка без словаря, как раньше.
        let useHint = ProcessInfo.processInfo.environment["SPEAKEY_SPEECH_HINT"] == "1"
        guard let bridge = WhisperBridge(modelPath: model.path, recognitionHint: useHint ? { VoiceDictionary.shared.recognitionHint() } : { nil }) else { throw Failure.modelUnavailable }
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        bridge.deterministic = options.deterministic
        let contextSources = try options.context.map(loadContext)
        let trace = SpeechDiagnosticTrace(samples: samples, configuration: ["scope": "isolated_whisper_bridge_no_dictionary"])
        let started = ProcessInfo.processInfo.systemUptime
        let firstText = bridge.transcribe(samples: samples, language: language, diagnostics: trace)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let snapshot = trace.snapshot(outcome: "replay")
        guard let result = snapshot.events.last(where: { $0.stage == "whisper_result" }),
              result.metadata["returnCode"] == "0" else { throw Failure.inferenceFailed }
        let configuration = snapshot.events.last(where: { $0.stage == "whisper_configuration" })
        var hypothesis = firstText
        var rawHypothesis = snapshot.events.last(where: { $0.stage == "whisper_raw" })?.text ?? ""
        var contextReport: [String: Any] = [:]
        if let contextSources {
            // Второй проход идёт при любых кандидатах, без бюджета времени приложения: замер должен видеть эффект.
            // Фильтр обычных слов — те же списки из ресурсов сборки, что в приложении.
            let candidates = ContextLexicon.candidates(for: firstText, sources: contextSources, limit: 8,
                                                       commonWords: ContextLexicon.bundledCommonWords)
            var secondRan = false, accepted = false
            var secondMs = 0
            if !candidates.isEmpty {
                let secondTrace = SpeechDiagnosticTrace(samples: samples, configuration: ["scope": "isolated_whisper_bridge_no_dictionary"])
                let secondStart = ProcessInfo.processInfo.systemUptime
                let second = bridge.transcribe(samples: samples, language: language, contextWords: candidates.map { $0.word }, diagnostics: secondTrace)
                secondMs = Int((ProcessInfo.processInfo.systemUptime - secondStart) * 1000)
                let secondSnapshot = secondTrace.snapshot(outcome: "replay")
                secondRan = secondSnapshot.events.last(where: { $0.stage == "whisper_result" })?.metadata["returnCode"] == "0"
                // `accepted` здесь — то же, что доставка в приложении: правило приёма и хотя бы одно
                // изменённое слово. T2 с теми же словами не подменяет оформление T1.
                accepted = secondRan && ContextualRedecode.shouldDeliver(first: firstText, second: second, candidates: candidates)
                if accepted {
                    hypothesis = second
                    rawHypothesis = secondSnapshot.events.last(where: { $0.stage == "whisper_raw" })?.text ?? rawHypothesis
                }
            }
            contextReport = ["context_candidates": candidates.map { $0.word }, "second_pass": secondRan, "accepted": accepted,
                             "first_ms": Int(elapsed * 1000), "second_ms": secondMs]
        }
        var config = configuration?.metadata ?? [:]
        config["prompt_sha256"] = digest(Data((configuration?.text ?? "").utf8))
        config["recognition_hint"] = "disabled_explicitly"
        config["gpu"] = "true"
        config["parameter_base"] = "linked_whisper_full_default_params_greedy_with_bridge_overrides"
        config["production_configuration_equivalent"] = "false_not_captured"
        if options.deterministic { config["deterministic"] = "temperature_inc_0" }
        if contextSources != nil { config["second_pass_policy"] = "always_when_candidates_no_budget_limit_8" }
        // Канонизация: UTF-8 JSON, сортировка ключей, без пробелов и экранирования слешей.
        let configData = try canonicalConfiguration(config)
        let document: [String: Any] = [
            "schema": 1, "engine": "whisper", "hypothesis": hypothesis,
            "raw_hypothesis": rawHypothesis,
            "model_sha256": modelHash, "language": language,
            "elapsed_seconds": elapsed, "model_load_seconds": loadSeconds,
            "sample_count": samples.count, "sample_rate": 16000,
            "input_wav_sha256": digest(input),
            "scope": "whisper_bridge_echo_cleaned_no_dictionary_no_output_options",
            "config": config, "config_sha256": digest(configData),
            "config_sha256_format": "sorted-compact-utf8-v1"
        ]
        let data = try JSONSerialization.data(withJSONObject: document.merging(contextReport) { current, _ in current },
                                              options: [.prettyPrinted, .sortedKeys])
        try SpeechDiagnosticsExport.writeNew(data, to: options.output)
    }

    /// Откуда CLI берёт словарь корпуса. В проверочной сборке тестов корпуса нет — тест подставляет свой.
    #if SPEAKEY_SPEECH_TEST
    static var vocabularyProvider: () throws -> [String: Int] = { throw Failure.corpusUnavailable }
    #else
    static var vocabularyProvider: () throws -> [String: Int] = {
        // Без файла корпуса не трогаем Keychain: `PersonalCorpus` создал бы там новый ключ.
        guard PersonalCorpus.defaultCorpusExists else { throw Failure.corpusUnavailable }
        let words = PersonalCorpus.shared.vocabulary(bundleID: nil)
        guard !words.isEmpty else { throw Failure.corpusUnavailable }
        return words
    }
    #endif

    /// Репозиторий, из которого собран CLI: туда личные файлы не пишем никогда.
    static let sourceRepository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Путь внутри репозитория сборки или любого git-репозитория (есть `.git` у предка).
    static func isInsideRepository(_ output: URL, repository: URL = sourceRepository) -> Bool {
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = repository.resolvingSymlinksInPath().standardizedFileURL.path
        if parent.path == root || parent.path.hasPrefix(root + "/") { return true }
        var directory = parent
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return true }
            directory.deleteLastPathComponent()
        }
        return false
    }

    /// `vocabulary --output <файл>`: словарь корпуса `{"слово": число}` для `context.py build
    /// --corpus-vocabulary`. Без надбавки приложения. Файл новый, `0600`, вне репозитория. В stdout —
    /// только число слов, сами слова не печатаются нигде.
    static func exportVocabulary(to output: URL) throws {
        guard !isInsideRepository(output) else { throw Failure.outputInRepository }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw SpeechDiagnosticsExport.Failure.outputExists }
        let words = try vocabularyProvider()
        let data = try JSONSerialization.data(withJSONObject: words, options: [.sortedKeys])
        try SpeechDiagnosticsExport.writeNew(data, to: output)
        print("{\"words\":\(words.count)}")
    }

    /// Файл `{"sources":[{"kind":"corpus","words":{"DPR":3}}]}`. Содержимое не печатается.
    static func loadContext(_ url: URL) throws -> [ContextSource] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 16 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let sources = root["sources"] as? [[String: Any]] else { throw SpeechDiagnosticsExport.Failure.invalidArguments }
        let kinds: [String: ContextSource.Kind] = ["screen": .screen, "recentDictation": .recentDictation,
                                                   "corpus": .corpus, "dictionary": .dictionary]
        return try sources.map { source in
            guard let name = source["kind"] as? String, let kind = kinds[name],
                  let words = source["words"] as? [String: Int] else { throw SpeechDiagnosticsExport.Failure.invalidArguments }
            return ContextSource(kind: kind, words: words)
        }
    }

    private static func transcribeParakeet(_ options: SpeechCLIArguments, load: SpeechParakeetEvaluation.Loader) async throws {
        guard !FileManager.default.fileExists(atPath: options.output.path) else { throw SpeechDiagnosticsExport.Failure.outputExists }
        guard let directory = options.model, let language = options.language else { throw Failure.modelUnavailable }
        let inputURL = try options.requireInput()
        let audioFile = try inputURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard audioFile.isRegularFile == true, let fileSize = audioFile.fileSize,
              fileSize <= SpeechFloatWAV.maximumByteCount else { throw SpeechDiagnosticsExport.Failure.invalidAudio }
        let input = try Data(contentsOf: inputURL)
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
