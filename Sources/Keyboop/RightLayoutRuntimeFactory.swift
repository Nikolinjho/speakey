import Foundation
import CoreML
import CryptoKit

// Временный compiled bundle живёт столько же, сколько модель: Core ML может читать его лениво.
private final class CompiledRightLayoutBackend: NeuralLayoutBackend {
    let model: RightLayoutModel
    let temporary: URL?
    init(model: RightLayoutModel, temporary: URL?) { self.model = model; self.temporary = temporary }
    deinit { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    func predict(_ word: String) throws -> NeuralLayoutScores { try model.predict(word) }
}

enum RightLayoutRuntimeFactory {
    private struct Manifest: Decodable {
        let modelID: String
        let sha256: String
        let inputLength: Int
        let classes: [String]
    }

    static func load() throws -> NeuralLayoutLoadedBackend {
        precondition(!Thread.isMainThread)
        var roots = [Bundle.main.resourceURL?.appendingPathComponent("RightLayout"), Bundle.main.resourceURL].compactMap { $0 }
        #if SWIFT_PACKAGE
        roots += [Bundle.module.resourceURL?.appendingPathComponent("RightLayout"), Bundle.module.resourceURL].compactMap { $0 }
        #endif
        guard let root = roots.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("model.json").path) }) else {
            throw NeuralLayoutError.unavailable
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("model.json")))
        let raw = root.appendingPathComponent("LayoutClassifier.mlmodel")
        guard manifest.modelID == "rightlayout-ensemble-20-v1", manifest.inputLength == 20,
              manifest.classes == ["ru", "en", "he", "ru_from_en", "he_from_en", "en_from_ru", "en_from_he", "he_from_ru", "ru_from_he"],
              manifest.sha256 == "5fab7216bce448129fe89e3e5d3fa63896cee8612364a72c631e24034e59f704" else {
            throw NeuralLayoutError.invalidManifest
        }
        let compiled = root.appendingPathComponent("LayoutClassifier.mlmodelc")
        let rawExists = FileManager.default.fileExists(atPath: raw.path)
        if rawExists {
            let digest = SHA256.hash(data: try Data(contentsOf: raw)).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256 else { throw NeuralLayoutError.invalidManifest }
        }
        let url: URL
        var temporary: URL?
        if FileManager.default.fileExists(atPath: compiled.path) { url = compiled }
        else {
            guard rawExists else { throw NeuralLayoutError.unavailable }
            url = try MLModel.compileModel(at: raw)
            temporary = url
        }
        do {
            let backend = CompiledRightLayoutBackend(model: try RightLayoutModel(modelURL: url), temporary: temporary)
            let profileData = try? Data(contentsOf: root.appendingPathComponent("profile.json"))
            let profile = profileData.flatMap { NeuralLayoutProfile.load($0, modelSHA256: manifest.sha256) }
            return NeuralLayoutLoadedBackend(backend: backend, modelID: manifest.modelID, sha256: manifest.sha256, profile: profile)
        } catch {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            throw error
        }
    }
}
