import Foundation

/// Источник слов контекста: экран, недавние диктовки, личный корпус или словарь.
struct ContextSource {
    enum Kind { case screen, recentDictation, corpus, dictionary }
    let kind: Kind
    let words: [String: Int]          // написание → сколько раз встречалось
}

struct ContextCandidate: Equatable {
    let word: String                  // как писать (самая частая форма из источников)
    let replaces: String              // слово расшифровки, как оно было
    let score: Double
}

/// Подбор слов-кандидатов на замену в расшифровке. Только Foundation, без состояния:
/// распознавание ошибается в звучании, поэтому сравниваем слова по грубому
/// фонетическому ключу (через кириллицу и латиницу сразу) и по основе слова.
enum ContextLexicon {
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static let translit: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya"
    ]
    private static let voicing: [Character: Character] = ["d": "t", "b": "p", "g": "k", "z": "s", "v": "f"]
    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// Грубый звуковой ключ: одинаково звучащие слова на кириллице и латинице дают один ключ.
    static func phoneticKey(_ word: String) -> String {
        var latin = ""
        for ch in word.lowercased() {
            latin += translit[ch] ?? String(ch)
        }
        // Глухие/звонкие склеиваем, чтобы «tpr» и «DPR» не расходились на первой букве.
        latin = latin.replacingOccurrences(of: "zh", with: "sh")
        latin = String(latin.map { voicing[$0] ?? $0 })
        latin = latin.replacingOccurrences(of: "ck", with: "k")
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "x", with: "ks")
            .replacingOccurrences(of: "q", with: "k")
        // «c» перед «h» — это «ch», его не трогаем.
        let chars = Array(latin)
        var mapped = ""
        for (i, ch) in chars.enumerated() {
            if ch == "c" && !(i + 1 < chars.count && chars[i + 1] == "h") {
                mapped.append("k")
            } else {
                mapped.append(ch)
            }
        }
        // Гласные нестабильны на слух, оставляем только первую букву слова.
        var result = ""
        for (i, ch) in mapped.enumerated() where i == 0 || !vowels.contains(ch) {
            if result.last != ch { result.append(ch) }
        }
        return result
    }

    private static let endings: [String] = {
        let list = "ами ями ого его ому ему ыми ими ах ях ов ев ей ой ий ый ая яя ое ее ые ие ом ем ок ек а я о е ы и у ю ь"
        return list.split(separator: " ").map(String.init).sorted { $0.count > $1.count }
    }()

    /// Основа слова: у кириллицы срезаем падежное окончание, латиницу не трогаем.
    static func stem(_ word: String) -> String {
        let lower = word.lowercased()
        let isCyrillic = !lower.isEmpty && lower.allSatisfy { $0.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) } }
        guard isCyrillic else { return lower }
        for ending in endings where lower.hasSuffix(ending) {
            let base = String(lower.dropLast(ending.count))
            return base.count >= 4 ? base : lower
        }
        return lower
    }

    private static func weight(_ kind: ContextSource.Kind) -> Double {
        switch kind {
        case .screen: return 3
        case .recentDictation, .dictionary: return 2
        case .corpus: return 1
        }
    }

    static func candidates(for transcript: String, sources: [ContextSource], limit: Int) -> [ContextCandidate] {
        guard limit > 0 else { return [] }
        let transcriptWords = words(in: transcript)
        guard !transcriptWords.isEmpty, sources.contains(where: { !$0.words.isEmpty }) else { return [] }

        // Ключи источников считаем один раз на форму, а не на каждое слово расшифровки.
        struct Form { let spelling: String; let lower: String; let phonetic: String; let stem: String }
        var known = Set<String>()
        var formsBySource: [(ContextSource.Kind, [(Form, Int)])] = []
        for source in sources {
            var forms: [(Form, Int)] = []
            for (spelling, count) in source.words {
                let lower = spelling.lowercased()
                known.insert(lower)
                forms.append((Form(spelling: spelling, lower: lower, phonetic: phoneticKey(spelling), stem: stem(spelling)), count))
            }
            formsBySource.append((source.kind, forms))
        }

        var result: [(candidate: ContextCandidate, order: Int)] = []
        var seen = Set<String>()
        for (order, w) in transcriptWords.enumerated() {
            let wl = w.lowercased()
            guard w.count >= 2, !known.contains(wl), seen.insert(wl).inserted else { continue }
            let wKey = phoneticKey(w)
            let wStem = stem(w)

            // Формы одного слова (без учёта регистра) складываем между источниками.
            var scores: [String: Double] = [:]
            var spellingCounts: [String: [String: Int]] = [:]
            for (kind, forms) in formsBySource {
                for (form, count) in forms {
                    var strength = 0.0
                    if form.phonetic == wKey && wKey.count >= 3 {
                        strength = 1.0
                    } else if form.stem == wStem && wStem.count >= 4 {
                        strength = 0.8
                    }
                    guard strength > 0 else { continue }
                    scores[form.lower, default: 0] += strength * weight(kind) * log(1 + Double(count))
                    spellingCounts[form.lower, default: [:]][form.spelling, default: 0] += count
                }
            }
            guard let best = scores.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
                  let spelling = spellingCounts[best.key]?.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key
            else { continue }
            result.append((ContextCandidate(word: spelling, replaces: w, score: best.value), order))
        }
        result.sort { $0.candidate.score != $1.candidate.score ? $0.candidate.score > $1.candidate.score : $0.order < $1.order }
        return Array(result.prefix(limit).map { $0.candidate })
    }
}
