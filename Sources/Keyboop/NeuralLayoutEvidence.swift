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

    func validate() throws {
        guard [ru, en, ruFromEn, enFromRu, unsupported].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              durationMs.isFinite, durationMs >= 0 else { throw LayoutJournalError.invalidNeuralEvidence }
    }
}
