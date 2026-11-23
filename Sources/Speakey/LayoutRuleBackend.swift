import Foundation

final class ExceptionLayoutRuleBackend: LayoutRuleBackend {
    let exceptions: ExceptionStore

    init(exceptions: ExceptionStore = .shared) { self.exceptions = exceptions }

    func membership(of word: String) -> LayoutRuleMembership {
        LayoutRuleMembership(ignored: exceptions.ignored.contains(word), learned: exceptions.learned.contains(word),
                             forceSwap: exceptions.forceSwap.contains(word))
    }

    func setMembership(_ value: LayoutRuleMembership, of word: String) {
        // Меняем только ключ квитанции. Остальные слова остаются пользовательскими.
        exceptions.setWordMembership(word, ignored: value.ignored, learned: value.learned, forceSwap: value.forceSwap)
    }

    func opposite(of word: String) -> String? {
        LayoutDetector.ruleCounterpart(of: word)
    }
}
