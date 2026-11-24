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

    static func weight(_ kind: ContextSource.Kind) -> Double {
        switch kind {
        case .screen: return 3
        case .recentDictation, .dictionary: return 2
        case .corpus: return 1
        }
    }

    /// Обычные слова языка (lowercase) из списков `words_ru.json` и `words_en.json` (массивы строк).
    /// Не прочитался файл — его слова просто не попадут в набор: фильтр станет мягче, но не сломается.
    static func loadCommonWords(urls: [URL]) -> Set<String> {
        var result = Set<String>()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { continue }
            for word in list { result.insert(word.lowercased()) }
        }
        return result
    }

    /// Списки из ресурсов приложения. Грузятся один раз и лениво, при первом подборе (не на main).
    /// В проверочных сборках без ресурсов набор пустой, и фильтр обычных слов не срабатывает.
    static let bundledCommonWords: Set<String> = loadCommonWords(urls: ["words_ru", "words_en"].compactMap {
        Bundle.main.url(forResource: $0, withExtension: "json")
    })

    /// Подбор по «сырым» источникам: индексы строятся на месте. Для повторных вызовов с тем же
    /// корпусом выгоднее `candidates(for:indexes:…)` с заранее построенным индексом.
    static func candidates(for transcript: String, sources: [ContextSource], limit: Int,
                           commonWords: Set<String> = []) -> [ContextCandidate] {
        candidates(for: transcript, indexes: sources.map { ContextSourceIndex($0) }, limit: limit, commonWords: commonWords)
    }

    /// Кандидаты на замену слов расшифровки.
    ///
    /// Фильтр обычных слов (спека: «кандидат не должен быть просто более частым обычным словом
    /// языка»). Кандидат, который сам обычное слово, не берём никогда: «что → чуть», «хорошо →
    /// хорошие» — это замена одного обычного слова другим, и звук тут Whisper слышал верно. Если
    /// обычное слово стоит в расшифровке, его заменяют только экран и словарь диктовки: это явный
    /// сигнал «сейчас пишу про Nuxt», а корпус и прошлые диктовки слишком широки — в них найдётся
    /// похожая форма почти для любого слова («Сделай → сделали»).
    ///
    /// Недавние диктовки — это сырой вывод Whisper, и однажды ослышанное «tpr» там уже лежит. Поэтому
    /// они не делают слово расшифровки «известным» (иначе ошибка закрепила бы сама себя), но
    /// кандидатов дают наравне с остальными источниками.
    static func candidates(for transcript: String, indexes: [ContextSourceIndex], limit: Int,
                           commonWords: Set<String> = []) -> [ContextCandidate] {
        guard limit > 0 else { return [] }
        let transcriptWords = words(in: transcript)
        guard !transcriptWords.isEmpty, indexes.contains(where: { !$0.isEmpty }) else { return [] }
        let knownIndexes = indexes.filter { $0.kind != .recentDictation }

        var result: [(candidate: ContextCandidate, order: Int)] = []
        var seen = Set<String>()
        for (order, w) in transcriptWords.enumerated() {
            let wl = w.lowercased()
            guard w.count >= 2, !knownIndexes.contains(where: { $0.lowers.contains(wl) }), seen.insert(wl).inserted else { continue }
            let wKey = phoneticKey(w)
            let wStem = stem(w)
            let wordIsCommon = commonWords.contains(wl)

            // Формы одного слова (без учёта регистра) складываем между источниками. Совпадение по
            // звуку сильнее совпадения по основе; форма, найденная обоими путями, считается раз.
            var scores: [String: Double] = [:]
            var spellingCounts: [String: [String: Int]] = [:]
            for index in indexes {
                if wordIsCommon && (index.kind == .corpus || index.kind == .recentDictation) { continue }
                let byKey = wKey.count >= 3 ? index.byKey[wKey] ?? [] : []
                let byStem = wStem.count >= 4 ? index.byStem[wStem] ?? [] : []
                guard !byKey.isEmpty || !byStem.isEmpty else { continue }
                let keyMatched = Set(byKey)
                for (position, strength) in byKey.map({ ($0, 1.0) }) + byStem.filter({ !keyMatched.contains($0) }).map({ ($0, 0.8) }) {
                    let form = index.forms[position]
                    // Кандидат должен отличаться от слова расшифровки (иначе «tpr» из прошлой диктовки
                    // перебил бы «DPR» из корпуса) и не быть обычным словом языка.
                    guard form.lower != wl, !commonWords.contains(form.lower) else { continue }
                    scores[form.lower, default: 0] += strength * weight(index.kind) * log(1 + Double(form.count))
                    spellingCounts[form.lower, default: [:]][form.spelling, default: 0] += form.count
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

/// Запомненные звуковой ключ и основа написания. Ключ — чистая функция слова, а считать его на
/// каждую из десятков тысяч форм корпуса при каждой диктовке — это сотни миллисекунд. Кэш общий
/// для всех источников и переживает пересборку корпуса: новые записи добавляют лишь новые слова.
final class ContextKeyCache {
    private let lock = NSLock()
    private var keys: [String: (phonetic: String, stem: String)] = [:]
    private let capacity: Int

    init(capacity: Int = 200_000) { self.capacity = capacity }

    func keys(for spelling: String) -> (phonetic: String, stem: String) {
        lock.lock()
        if let cached = keys[spelling] { lock.unlock(); return cached }
        lock.unlock()
        let computed = (ContextLexicon.phoneticKey(spelling), ContextLexicon.stem(spelling))
        lock.lock()
        // Переполнение — сбрасываем целиком: проще и честнее LRU для словаря, который растёт медленно.
        if keys.count >= capacity { keys.removeAll(keepingCapacity: true) }
        keys[spelling] = computed
        lock.unlock()
        return computed
    }
}

/// Источник, разложенный для поиска: формы и их позиции по звуковому ключу и по основе. Подбор
/// смотрит только в нужные корзины, а не перебирает все формы на каждое слово расшифровки.
struct ContextSourceIndex {
    struct Form { let spelling: String; let lower: String; let count: Int }
    let kind: ContextSource.Kind
    let forms: [Form]
    let byKey: [String: [Int]]
    let byStem: [String: [Int]]
    let lowers: Set<String>
    var isEmpty: Bool { forms.isEmpty }

    init(_ source: ContextSource, keys cache: ContextKeyCache? = nil) {
        var forms: [Form] = []
        var byKey: [String: [Int]] = [:]
        var byStem: [String: [Int]] = [:]
        var lowers = Set<String>()
        forms.reserveCapacity(source.words.count)
        for (spelling, count) in source.words {
            let keys = cache?.keys(for: spelling) ?? (phonetic: ContextLexicon.phoneticKey(spelling), stem: ContextLexicon.stem(spelling))
            let lower = spelling.lowercased()
            byKey[keys.phonetic, default: []].append(forms.count)
            byStem[keys.stem, default: []].append(forms.count)
            lowers.insert(lower)
            forms.append(Form(spelling: spelling, lower: lower, count: count))
        }
        kind = source.kind
        self.forms = forms; self.byKey = byKey; self.byStem = byStem; self.lowers = lowers
    }
}
