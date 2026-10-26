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
        // Пунктуация, цифры и смешанные токены имеют другие ключи в каскаде детектора.
        // Пока поддерживаем только однородные буквенные пары без такого расширения области правила.
        let normalized = word.lowercased()
        let latin = normalized.unicodeScalars.allSatisfy { (97...122).contains(Int($0.value)) }
        let cyrillic = normalized.unicodeScalars.allSatisfy { (1072...1103).contains(Int($0.value)) || $0.value == 1105 }
        guard !word.isEmpty, !ExtraWords.defaultKeep.contains(normalized), latin != cyrillic else { return nil }
        let target = Keymap.convert(word, toCyrillic: latin)
        guard target.allSatisfy({ $0.isLetter }), target != word,
              Keymap.convert(target, toCyrillic: !latin) == word else { return nil }
        return target
    }
}
