import Foundation

enum NeuralLayoutMode: String, Codable, CaseIterable {
    case off, observe, assist
}

enum NeuralLayoutError: Error, Equatable {
    case invalidToken, invalidOutput, unavailable, invalidManifest
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
