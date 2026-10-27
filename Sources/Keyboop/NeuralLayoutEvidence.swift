import Foundation

struct NeuralLayoutEvidence: Codable, Equatable {
    let modelID: String
    let modelSHA256: String
    let mode: NeuralLayoutMode
    let ru: Double
    let en: Double
    let ruFromEn: Double
    let enFromRu: Double
    let unsupported: Double
    let durationMs: Double
    let proposedCyrillic: Bool?
    let block: NeuralLayoutBlock?
    let disagreesWithDetector: Bool
    var classScores: [String: Double]? = nil
    static let classNames = ["ru", "en", "he", "ruFromEn", "heFromEn", "enFromRu", "enFromHe", "heFromRu", "ruFromHe"]

    func validate() throws {
        if let classScores {
            guard Set(classScores.keys) == Set(Self.classNames),
                  classScores.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw LayoutJournalError.invalidNeuralEvidence
            }
        }
        guard [ru, en, ruFromEn, enFromRu, unsupported].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              durationMs.isFinite, durationMs >= 0 else { throw LayoutJournalError.invalidNeuralEvidence }
    }
}
