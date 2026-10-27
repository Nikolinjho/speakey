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
