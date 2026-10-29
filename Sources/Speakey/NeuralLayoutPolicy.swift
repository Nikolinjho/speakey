enum NeuralLayoutPolicy {
    static func evaluate(scores: NeuralLayoutScores, admission: NeuralLayoutAdmission) -> NeuralLayoutPolicyResult {
        switch admission.mode {
        case .off: return .blocked(.disabled)
        case .observe: return .observe
        case .assist: break
        }
        if let block = admission.block { return .blocked(block) }
        guard let profile = admission.profile, profile.enabled,
              profile.modelSHA256 == admission.modelSHA256 else { return .observe }
        guard admission.fresh else { return .blocked(.stale) }
        guard (4...16).contains(admission.wordLength) else { return .blocked(.length) }
        let target: NeuralLayoutClass = admission.sourceCyrillic ? .enFromRu : .ruFromEn
        let winner = NeuralLayoutClass.allCases.max { scores[$0] < scores[$1] }!
        switch winner {
        case .he, .heFromEn, .enFromHe, .heFromRu, .ruFromHe: return .blocked(.unsupported)
        default: break
        }
        guard winner == target else { return .blocked(.confidence) }
        let other = NeuralLayoutClass.allCases.filter { $0 != target }.map { scores[$0] }.max()!
        let margin = scores[target] - other
        // Softmax score сравнивается с порогом профиля и не является калиброванной уверенностью.
        guard scores[target] >= profile.minimumScore, margin > 0,
              margin >= profile.minimumMargin else { return .blocked(.confidence) }
        return .propose(toCyrillic: !admission.sourceCyrillic)
    }
}
