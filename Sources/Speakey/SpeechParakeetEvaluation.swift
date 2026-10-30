import Foundation
import CryptoKit
#if arch(arm64) && !SPEAKEY_NO_PARAKEET && !SPEAKEY_SPEECH_TEST
import FluidAudio
#endif

/// Отдельный менеджер локального v3, без singleton, загрузчиков из сети и фильтров приложения.
enum SpeechParakeetEvaluation {
    enum Failure: Error { case unavailable, invalidDirectory, modelChanged }
    #if arch(arm64) && !SPEAKEY_NO_PARAKEET && !SPEAKEY_SPEECH_TEST
    static var directoryName: String { Repo.parakeetV3.folderName }
    #else
    static let directoryName = "parakeet-tdt-0.6b-v3"
    #endif
    static let components = ["Decoder.mlmodelc", "Encoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc", "parakeet_vocab.json"]
    struct Loaded {
        let configuration: [String: String]
        let transcribe: ([Float], String) async throws -> String
    }
    struct Result {
        let hypothesis: String
        let modelSHA256: String
        let loadSeconds: Double
        let elapsedSeconds: Double
        let configuration: [String: String]
    }
    typealias Loader = (URL) async throws -> Loaded

    static func transcribe(samples: [Float], language: String, directory: URL,
                           load: Loader = loadLocal) async throws -> Result {
        let manifest = try modelManifest(directory: directory)
        let loadStart = ProcessInfo.processInfo.systemUptime
        let loaded = try await load(directory)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart
        guard try modelManifest(directory: directory) == manifest else { throw Failure.modelChanged }
        let started = ProcessInfo.processInfo.systemUptime
        let text = try await loaded.transcribe(samples, language)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard try modelManifest(directory: directory) == manifest else { throw Failure.modelChanged }
        return Result(hypothesis: text, modelSHA256: digest(manifest), loadSeconds: loadSeconds,
                      elapsedSeconds: elapsed, configuration: loaded.configuration)
    }

    /// JSON UTF-8 без пробелов: [[relativeASCIIPath,sha256],...], строки отсортированы по пути.
    /// Проверяется всё дерево. В хеш входят только файлы пяти реально загружаемых компонентов.
    static func modelManifest(directory: URL) throws -> Data {
        let manager = FileManager.default
        guard directory.lastPathComponent == directoryName,
              try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.invalidDirectory
        }
        for component in components {
            let url = directory.appendingPathComponent(component)
            let expected: FileAttributeType = component.hasSuffix(".mlmodelc") ? .typeDirectory : .typeRegular
            guard try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == expected else { throw Failure.invalidDirectory }
            if expected == .typeDirectory {
                guard try manager.attributesOfItem(atPath: url.appendingPathComponent("coremldata.bin").path)[.type] as? FileAttributeType == .typeRegular else {
                    throw Failure.invalidDirectory
                }
            }
        }
        var paths: [String] = []
        func visit(_ url: URL, relative: String) throws {
            guard relative.utf8.allSatisfy({ $0 < 128 }) else { throw Failure.invalidDirectory }
            let kind = try manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if kind == .typeDirectory {
                for child in try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            } else if kind == .typeRegular {
                if components.contains(String(relative.split(separator: "/")[0])) { paths.append(relative) }
            } else { throw Failure.invalidDirectory }
        }
        try visit(directory, relative: "")
        let entries = try paths.sorted().map { path in [path, try fileDigest(directory.appendingPathComponent(path))] }
        return try JSONSerialization.data(withJSONObject: entries, options: [.withoutEscapingSlashes])
    }

    static func loadLocal(directory: URL) async throws -> Loaded {
        #if arch(arm64) && !SPEAKEY_NO_PARAKEET && !SPEAKEY_SPEECH_TEST
        DownloadUtils.enforceOffline = true
        // FluidAudio использует имя repo внутри родительского каталога. modelManifest проверяет его.
        let models = try await AsrModels.load(from: directory, version: .v3, encoderPrecision: .int8)
        let config = ASRConfig(melChunkContext: false)
        let manager = AsrManager(config: config)
        try await manager.loadModels(models)
        let layers = await manager.decoderLayerCount
        let metadata = [
            "melChunkContext": String(config.melChunkContext), "dualDecodeArbitration": String(config.dualDecodeArbitration),
            "sampleRate": String(config.sampleRate), "parallelChunkConcurrency": String(config.parallelChunkConcurrency),
            "streamingEnabled": String(config.streamingEnabled), "streamingThreshold": String(config.streamingThreshold),
            "encoderHiddenSize": String(config.encoderHiddenSize), "decoderLayers": String(layers),
            "tdtConfig": String(reflecting: config.tdtConfig), "compute_units": "cpuAndNeuralEngine_preprocessor_cpuOnly"
        ]
        return Loaded(configuration: metadata, transcribe: { samples, language in
            var state = TdtDecoderState.make(decoderLayers: layers)
            let result = try await manager.transcribe(samples, decoderState: &state, language: Language(rawValue: language))
            return result.text
        })
        #else
        throw Failure.unavailable
        #endif
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func fileDigest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
