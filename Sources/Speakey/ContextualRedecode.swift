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
    ///
    /// Сторож транскрипции считает от `beginTranscription`, а не от начала T1: до T1 диктовка могла
    /// ждать очередь (предыдущая диктовка, импорт) и загрузку модели. Поэтому `elapsedSeconds` —
    /// сколько прошло от начала транскрипции до конца T1, а вторую расшифровку оцениваем как первую:
    /// `elapsed + first <= 0.6 * timeout`. Если `elapsed` вдруг меньше T1 (часы разных потоков),
    /// берём T1 — бюджет от этого не станет щедрее прежнего `2 * first`.
    ///
    /// Если в очереди ждёт другая транскрипция, второго прохода нет: её сторож уже идёт, и наш T2
    /// отнял бы у неё время. T1 приоритетнее всегда.
    static func shouldRunSecondPass(elapsedSeconds: Double, firstPassSeconds: Double, timeoutSeconds: Double,
                                    candidateCount: Int, waitingTranscriptions: Int) -> Bool {
        guard candidateCount > 0, waitingTranscriptions == 0 else { return false }
        return max(elapsedSeconds, firstPassSeconds) + firstPassSeconds <= budgetShare * timeoutSeconds
    }

    /// Сколько слов T2 отличается от T1 (без учёта регистра и пунктуации). nil — число слов разное.
    static func changedWordCount(first: String, second: String) -> Int? {
        let firstWords = ContextLexicon.words(in: first)
        let secondWords = ContextLexicon.words(in: second)
        guard firstWords.count == secondWords.count else { return nil }
        return zip(firstWords, secondWords).filter { $0.lowercased() != $1.lowercased() }.count
    }

    /// Отдать T2 вместо T1: прошёл `accept` и поменял хотя бы одно слово. Уточнение меняет слова,
    /// а не оформление (не цель спеки), поэтому T2 с теми же словами не заменяет пунктуацию и
    /// регистр T1. Одно правило для приложения и стенда.
    static func shouldDeliver(first: String, second: String, candidates: [ContextCandidate]) -> Bool {
        guard let changed = changedWordCount(first: first, second: second), changed > 0 else { return false }
        return accept(first: first, second: second, candidates: candidates)
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
