import Foundation

/// Решения для второго прохода Whisper с контекстом: запускать ли его и принимать ли результат.
/// Чистые функции без состояния, поверх `ContextLexicon`.
enum ContextualRedecode {
    /// Какую долю таймаута может занять второй проход.
    static let budgetShare = 0.6
    /// Какую долю слов расшифровки можно изменить (с минимумом в одно слово).
    static let maxChangedShare = 0.3
    /// Минимальная длина общего префикса основ, при котором новое слово считается формой кандидата.
    static let minSharedStemPrefix = 5

    /// Второй проход нужен, если есть кандидаты и он уложится в бюджет времени.
    /// Вторую расшифровку оцениваем как первую, поэтому требуем `2 * first <= 0.6 * timeout`.
    static func shouldRunSecondPass(firstPassSeconds: Double, timeoutSeconds: Double, candidateCount: Int) -> Bool {
        guard candidateCount > 0 else { return false }
        return firstPassSeconds * 2 <= budgetShare * timeoutSeconds
    }

    /// Принять вторую расшифровку, только если она отличается от первой заменами на кандидатов:
    /// то же число слов, изменённых слов не больше лимита, каждая замена — на форму кандидата.
    static func accept(first: String, second: String, candidates: [ContextCandidate]) -> Bool {
        let firstWords = ContextLexicon.words(in: first)
        let secondWords = ContextLexicon.words(in: second)
        if !firstWords.isEmpty && secondWords.isEmpty { return false }
        guard firstWords.count == secondWords.count else { return false }

        let allowedChanges = max(1, Int(maxChangedShare * Double(firstWords.count)))
        var changed = 0
        for (old, new) in zip(firstWords, secondWords) where old.lowercased() != new.lowercased() {
            changed += 1
            if changed > allowedChanges { return false }
            guard isCandidateReplacement(old: old, new: new, candidates: candidates) else { return false }
        }
        return true
    }

    /// Замена допустима, если кандидат заменяет именно это слово и новое слово — его форма.
    private static func isCandidateReplacement(old: String, new: String, candidates: [ContextCandidate]) -> Bool {
        let oldLower = old.lowercased()
        let newLower = new.lowercased()
        return candidates.contains { candidate in
            guard candidate.replaces.lowercased() == oldLower else { return false }
            return isForm(newLower, of: candidate.word)
        }
    }

    /// Форма слова: совпадает с написанием без учёта регистра или делит с ним основу (общий префикс не короче порога).
    private static func isForm(_ word: String, of candidateWord: String) -> Bool {
        if word == candidateWord.lowercased() { return true }
        let wordStem = ContextLexicon.stem(word)
        let candidateStem = ContextLexicon.stem(candidateWord)
        if wordStem == candidateStem { return true }
        return commonPrefixLength(wordStem, candidateStem) >= minSharedStemPrefix
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            guard x == y else { break }
            count += 1
        }
        return count
    }
}
