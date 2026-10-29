import Foundation

enum NeuralLayoutMode: String, Codable, CaseIterable {
    case off, observe, assist
}

enum NeuralLayoutError: Error, Equatable {
    case invalidToken, invalidOutput, unavailable, invalidManifest, invalidProfile
}

enum NeuralLayoutClass: Int, Codable, CaseIterable {
    case ru, en, he, ruFromEn, heFromEn, enFromRu, enFromHe, heFromRu, ruFromHe
}

struct NeuralLayoutScores: Equatable {
    let values: [Double]

    init(logits: [Double]) throws {
        guard logits.count == NeuralLayoutClass.allCases.count,
              logits.allSatisfy({ $0.isFinite }), let maximum = logits.max() else {
            throw NeuralLayoutError.invalidOutput
        }
        let exponentials = logits.map { exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total.isFinite, total > 0 else { throw NeuralLayoutError.invalidOutput }
        values = exponentials.map { $0 / total }
    }

    subscript(_ label: NeuralLayoutClass) -> Double { values[label.rawValue] }
}

protocol NeuralLayoutBackend {
    func predict(_ word: String) throws -> NeuralLayoutScores
}

struct NeuralLayoutRequest: Hashable {
    let epoch: UUID
    let revision: UInt64
    let occurrenceID: UUID
    let bundleID: String
    let layoutCode: String
    let word: String
}

struct NeuralLayoutResult {
    let request: NeuralLayoutRequest
    let scores: NeuralLayoutScores
    let durationMs: Double
}

struct NeuralLayoutSession {
    private(set) var epoch = UUID()
    private(set) var revision: UInt64 = 0

    mutating func changed() { revision &+= 1 }

    mutating func invalidate() {
        epoch = UUID()
        revision &+= 1
    }

    func matches(_ request: NeuralLayoutRequest, occurrenceID: UUID?, bundleID: String,
                 layoutCode: String, word: String) -> Bool {
        request.epoch == epoch && request.revision == revision
            && request.occurrenceID == occurrenceID && request.bundleID == bundleID
            && request.layoutCode == layoutCode && request.word == word
    }
}

struct NeuralLayoutProfile: Codable {
    let modelSHA256: String
    let enabled: Bool
    let minimumScore: Double
    let minimumMargin: Double

    init(modelSHA256: String, enabled: Bool, minimumScore: Double, minimumMargin: Double) throws {
        guard modelSHA256.utf8.count == 64,
              modelSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
              minimumScore.isFinite, (0...1).contains(minimumScore),
              minimumMargin.isFinite, (0...1).contains(minimumMargin) else {
            throw NeuralLayoutError.invalidProfile
        }
        self.modelSHA256 = modelSHA256
        self.enabled = enabled
        self.minimumScore = minimumScore
        self.minimumMargin = minimumMargin
    }

    private enum CodingKeys: String, CodingKey {
        case modelSHA256, enabled, minimumScore, minimumMargin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(modelSHA256: values.decode(String.self, forKey: .modelSHA256),
                      enabled: values.decode(Bool.self, forKey: .enabled),
                      minimumScore: values.decode(Double.self, forKey: .minimumScore),
                      minimumMargin: values.decode(Double.self, forKey: .minimumMargin))
    }
}

enum NeuralLayoutBlock: String, Codable, Equatable {
    case disabled, unavailable, profile, stale, length, unsupported, confidence
    case app, developer, secureInput, modifiers, editing, syntheticFlight, undo, rule, resonance, keymap
}

enum NeuralLayoutPolicyResult: Equatable {
    case observe
    case blocked(NeuralLayoutBlock)
    case propose(toCyrillic: Bool)
}

struct NeuralLayoutAdmission {
    let mode: NeuralLayoutMode
    let modelSHA256: String
    let profile: NeuralLayoutProfile?
    let fresh: Bool
    let block: NeuralLayoutBlock?
    let wordLength: Int
    let sourceCyrillic: Bool
}

// Общий admission для CLI и live-пути, без зависимости от Core ML.
enum NeuralLayoutToken {
    static func assistanceSupported(_ word: String) -> Bool {
        var latin = false, russian = false
        let punctuation = Set("0123456789-=[]\\;',./`!@#$%^&*()_+{}|:\"<>?~")
        for char in word {
            if char.isASCII && char.isLetter { latin = true }
            else if "абвгдеёжзийклмнопрстуфхцчшщъыьэюя".contains(char.lowercased()) { russian = true }
            else if !punctuation.contains(char) { return false }
        }
        return latin != russian
    }
}
// Условия допуска общие для оценочного CLI и загрузчика поставляемого профиля.
enum NeuralLayoutQuality {
    static func ready(baselineFP: Int, assistedFP: Int, baselineRecall: Double, assistedRecall: Double) -> Bool {
        assistedFP <= baselineFP && assistedRecall - baselineRecall >= 0.05 - 1e-12
    }
    struct Metrics: Decodable {
        let correctTokens: Int
        let wrongTokens: Int
        let truePositives: Int
        let falsePositives: Int
        let adverseWrongConversions: Int
        let additionalFalseConversions: Int
        var valid: Bool {
            correctTokens >= 0 && wrongTokens > 0 && correctTokens <= Int.max - wrongTokens
                && (0...wrongTokens).contains(truePositives)
                && (0...correctTokens).contains(falsePositives)
                && (0...(wrongTokens - truePositives)).contains(adverseWrongConversions)
                && (0...(correctTokens + wrongTokens)).contains(additionalFalseConversions)
        }
        var recall: Double { Double(truePositives) / Double(wrongTokens) }
    }
    struct Comparison: Decodable {
        let baseline: Metrics
        let assisted: Metrics
        var valid: Bool {
            baseline.valid && assisted.valid && baseline.additionalFalseConversions == 0
                && baseline.correctTokens == assisted.correctTokens
                && baseline.wrongTokens == assisted.wrongTokens
        }
        var safe: Bool {
            assisted.additionalFalseConversions == 0 && assisted.falsePositives <= baseline.falsePositives
                && assisted.adverseWrongConversions <= baseline.adverseWrongConversions
        }
        var ready: Bool {
            valid && safe && NeuralLayoutQuality.ready(baselineFP: baseline.falsePositives,
                assistedFP: assisted.falsePositives, baselineRecall: baseline.recall, assistedRecall: assisted.recall)
        }
    }
}
extension NeuralLayoutProfile {
    static let policyVersion = "rightlayout-live-policy-v1"
    static func load(_ data: Data, modelSHA256: String) -> NeuralLayoutProfile? {
        struct Metadata: Decodable {
            let policyVersion: String
            let fixturesSHA256: String
            let splitsSHA256: String
            let detectorSHA256: String
            let reason: String
            let calibration: NeuralLayoutQuality.Comparison
            let holdout: NeuralLayoutQuality.Comparison
        }
        guard let profile = try? JSONDecoder().decode(Self.self, from: data),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
              profile.modelSHA256 == modelSHA256, metadata.policyVersion == policyVersion,
              metadata.calibration.valid, metadata.holdout.valid,
              metadata.holdout.baseline.correctTokens >= 2000, metadata.holdout.baseline.wrongTokens >= 200,
              [metadata.fixturesSHA256, metadata.splitsSHA256, metadata.detectorSHA256].allSatisfy({ sha in
                  sha.count == 64 && sha.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }) else { return nil }
        if profile.enabled {
            guard metadata.reason == "holdout-criteria-met", metadata.calibration.safe,
                  metadata.holdout.ready else { return nil }
        } else {
            switch metadata.reason {
            case "recall-gain-below-0.05":
                guard metadata.holdout.safe && !metadata.holdout.ready else { return nil }
            case "additional-false-conversions":
                guard metadata.holdout.assisted.additionalFalseConversions > 0 else { return nil }
            case "no-safe-calibration-profile":
                guard !metadata.calibration.safe else { return nil }
            default: return nil
            }
        }
        return profile
    }
}
