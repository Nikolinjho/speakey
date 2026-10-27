import Foundation

enum Quality {
    static func ready(baselineFP: Int, assistedFP: Int, baselineRecall: Double, assistedRecall: Double) -> Bool { NeuralLayoutQuality.ready(baselineFP: baselineFP, assistedFP: assistedFP, baselineRecall: baselineRecall, assistedRecall: assistedRecall) }
    static func disjoint(calibration: Set<String>, holdout: Set<String>) -> Bool { calibration.isDisjoint(with: holdout) }
    static func correct(target: String, result: String) -> Bool { result == target }
}
