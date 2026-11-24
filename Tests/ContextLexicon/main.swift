import Foundation

var checks = 0, failures = 0
func check(_ name: String, _ value: Bool) {
    checks += 1
    if !value { failures += 1 }
    print("\(value ? "PASS" : "FAIL"): \(name)")
}

let corpus = ContextSource(kind: .corpus, words: ["DPR": 3, "dpr": 1, "подборки": 6, "подборок": 4, "мобилке": 2])
let example = "Посмотри на этой странице на мобилке, какое tpr у фоток подбора."
let found = ContextLexicon.candidates(for: example, sources: [corpus], limit: 8)
check("tpr получает кандидата DPR", found.contains { $0.replaces == "tpr" && $0.word == "DPR" })
check("подбора получает форму подборки/подборок", found.contains { $0.replaces == "подбора" && ["подборки", "подборок"].contains($0.word) })
check("мобилке без кандидатов", !found.contains { $0.replaces == "мобилке" })
check("пустые источники", ContextLexicon.candidates(for: example, sources: [], limit: 8).isEmpty)
check("пустая расшифровка", ContextLexicon.candidates(for: "", sources: [corpus], limit: 8).isEmpty)
check("кириллица ↔ латиница", ContextLexicon.candidates(for: "открой спики", sources: [ContextSource(kind: .dictionary, words: ["Speakey": 1])], limit: 8).first?.word == "Speakey")
check("next ↔ Nuxt", ContextLexicon.candidates(for: "проверь next", sources: [ContextSource(kind: .screen, words: ["Nuxt": 2])], limit: 8).first?.word == "Nuxt")
check("ключ tpr == ключ DPR", ContextLexicon.phoneticKey("tpr") == ContextLexicon.phoneticKey("DPR"))
check("основа подбора == основа подборок", ContextLexicon.stem("подбора") == ContextLexicon.stem("подборок"))
check("лимит соблюдается", ContextLexicon.candidates(for: example, sources: [corpus], limit: 1).count == 1)
check("words(in:) без пунктуации, порядок сохранён", ContextLexicon.words(in: "Привет, мир! DPR-2.") == ["Привет", "мир", "DPR", "2"])
check("латиница в основе не меняется", ContextLexicon.stem("Nuxt") == "nuxt")
check("вес screen выше corpus", {
    let w = ["Nuxt": 2]
    let s = ContextLexicon.candidates(for: "next", sources: [ContextSource(kind: .screen, words: w)], limit: 1).first?.score ?? 0
    let c = ContextLexicon.candidates(for: "next", sources: [ContextSource(kind: .corpus, words: w)], limit: 1).first?.score ?? 0
    return s > c && c > 0
}())


// Фильтр обычных слов языка: настоящие списки приложения из ресурсов репозитория.
let common = ContextLexicon.loadCommonWords(urls: ["words_ru", "words_en"].map {
    URL(fileURLWithPath: "Sources/Speakey/Resources/\($0).json")
})
check("списки обычных слов прочитаны", common.contains("что") && common.contains("next") && !common.contains("dpr"))
let everyday = ["чуть": 5, "хорошие": 4, "сделали": 3, "Чуть": 1]
for kind in [ContextSource.Kind.corpus, .recentDictation, .screen, .dictionary] {
    let src = [ContextSource(kind: kind, words: everyday)]
    check("обычная фраза без кандидатов (\(kind))", ContextLexicon.candidates(for: "Я думаю, что это хорошо работает.", sources: src, limit: 8, commonWords: common).isEmpty)
    check("Сделай без кандидатов (\(kind))", ContextLexicon.candidates(for: "Сделай", sources: src, limit: 8, commonWords: common).isEmpty)
}
let withCommon = ContextLexicon.candidates(for: example, sources: [corpus], limit: 8, commonWords: common)
check("пример Ники с фильтром: tpr → DPR", withCommon.contains { $0.replaces == "tpr" && $0.word == "DPR" })
check("пример Ники с фильтром: подбора → подборки/подборок", withCommon.contains { $0.replaces == "подбора" && ["подборки", "подборок"].contains($0.word) })
check("обычное слово меняет только экран: next → Nuxt", ContextLexicon.candidates(for: "проверь next", sources: [ContextSource(kind: .screen, words: ["Nuxt": 2])], limit: 8, commonWords: common).first?.word == "Nuxt")
check("обычное слово меняет словарь", ContextLexicon.candidates(for: "проверь next", sources: [ContextSource(kind: .dictionary, words: ["Nuxt": 1])], limit: 8, commonWords: common).first?.word == "Nuxt")
check("корпус обычное слово не трогает", ContextLexicon.candidates(for: "проверь next", sources: [ContextSource(kind: .corpus, words: ["Nuxt": 9])], limit: 8, commonWords: common).isEmpty)
check("недавние диктовки обычное слово не трогают", ContextLexicon.candidates(for: "проверь next", sources: [ContextSource(kind: .recentDictation, words: ["Nuxt": 9])], limit: 8, commonWords: common).isEmpty)

// Недавние диктовки не делают слово «известным»: однажды ослышанное tpr не закрепляется.
let misheard = ContextLexicon.candidates(for: "какое tpr", sources: [ContextSource(kind: .recentDictation, words: ["tpr": 2]), ContextSource(kind: .corpus, words: ["DPR": 3])], limit: 8)
check("tpr из недавних диктовок не блокирует DPR", misheard.contains { $0.replaces == "tpr" && $0.word == "DPR" })
check("недавние диктовки дают кандидатов", ContextLexicon.candidates(for: "какое tpr", sources: [ContextSource(kind: .recentDictation, words: ["DPR": 2])], limit: 8).first?.word == "DPR")
check("корпус по-прежнему делает слово известным", ContextLexicon.candidates(for: "какое tpr", sources: [ContextSource(kind: .corpus, words: ["tpr": 1, "DPR": 3])], limit: 8).isEmpty)

// Индекс даёт то же, что прямой перебор всех форм (эталонная реализация ниже — прежний алгоритм
// с теми же правилами известных и обычных слов).
func bruteForce(_ transcript: String, _ sources: [ContextSource], _ limit: Int, _ commonWords: Set<String>) -> [ContextCandidate] {
    let tw = ContextLexicon.words(in: transcript)
    var known = Set<String>()
    for s in sources where s.kind != .recentDictation { for w in s.words.keys { known.insert(w.lowercased()) } }
    var result: [(ContextCandidate, Int)] = []
    var seen = Set<String>()
    for (order, w) in tw.enumerated() {
        let wl = w.lowercased()
        guard w.count >= 2, !known.contains(wl), seen.insert(wl).inserted else { continue }
        let wKey = ContextLexicon.phoneticKey(w), wStem = ContextLexicon.stem(w)
        var scores: [String: Double] = [:], spellings: [String: [String: Int]] = [:]
        for s in sources {
            if commonWords.contains(wl) && (s.kind == .corpus || s.kind == .recentDictation) { continue }
            for (spelling, count) in s.words {
                let lower = spelling.lowercased()
                guard lower != wl, !commonWords.contains(lower) else { continue }
                var strength = 0.0
                if ContextLexicon.phoneticKey(spelling) == wKey && wKey.count >= 3 { strength = 1 }
                else if ContextLexicon.stem(spelling) == wStem && wStem.count >= 4 { strength = 0.8 }
                guard strength > 0 else { continue }
                scores[lower, default: 0] += strength * ContextLexicon.weight(s.kind) * log(1 + Double(count))
                spellings[lower, default: [:]][spelling, default: 0] += count
            }
        }
        guard let best = scores.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              let spelling = spellings[best.key]?.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key else { continue }
        result.append((ContextCandidate(word: spelling, replaces: w, score: best.value), order))
    }
    result.sort { $0.0.score != $1.0.score ? $0.0.score > $1.0.score : $0.1 < $1.1 }
    return result.prefix(limit).map { $0.0 }
}
func same(_ a: [ContextCandidate], _ b: [ContextCandidate]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.word == $1.word && $0.replaces == $1.replaces && abs($0.score - $1.score) < 1e-9 }
}
// Синтетический корпус ~30 тысяч форм: смесь кириллицы и латиницы, повторяющиеся основы.
var generator = SystemRandomNumberGenerator()
let letters = Array("абвгдежзиклмнопрстуфхцчшщыэюяabcdefghijklmnopqrstuvwxyz")
var big: [String: Int] = ["DPR": 3, "подборки": 6, "подборок": 4, "Nuxt": 2, "Speakey": 5]
while big.count < 30_000 {
    let length = Int.random(in: 3...10, using: &generator)
    big[String((0..<length).map { _ in letters.randomElement(using: &generator)! }), default: 0] += Int.random(in: 1...9, using: &generator)
}
let bigSources = [ContextSource(kind: .screen, words: ["Nuxt": 2, "next": 1]), ContextSource(kind: .recentDictation, words: ["tpr": 1, "спики": 1]),
                  ContextSource(kind: .corpus, words: big), ContextSource(kind: .dictionary, words: ["Speakey": 1])]
let cache = ContextKeyCache()
let corpusIndex = ContextSourceIndex(bigSources[2], keys: cache)
let prebuilt = [ContextSourceIndex(bigSources[0]), ContextSourceIndex(bigSources[1]), corpusIndex, ContextSourceIndex(bigSources[3])]
let phrases = [example, "открой спики и проверь next", "Я думаю, что это хорошо работает.", "какое tpr у фоток подбора", "",
               "абв где жзи клм нопр стуф", "Сделай мне Nuxt проект"]
for phrase in phrases {
    for cw in [Set<String>(), common] {
        let reference = bruteForce(phrase, bigSources, 8, cw)
        check("индекс == перебор: «\(phrase.prefix(20))» \(cw.isEmpty ? "без" : "с") фильтром",
              same(ContextLexicon.candidates(for: phrase, indexes: prebuilt, limit: 8, commonWords: cw), reference)
              && same(ContextLexicon.candidates(for: phrase, sources: bigSources, limit: 8, commonWords: cw), reference))
    }
}
check("кэш ключей даёт тот же индекс", same(ContextLexicon.candidates(for: example, indexes: [ContextSourceIndex(bigSources[2], keys: cache)], limit: 8),
                                          ContextLexicon.candidates(for: example, indexes: [ContextSourceIndex(bigSources[2])], limit: 8)))
// Время: перебор на каждый вызов против готового индекса (печатаем, не проверяем — машина шумит).
let clock = { DispatchTime.now().uptimeNanoseconds }
var t0 = clock()
_ = bruteForce(example, bigSources, 8, common)
let bruteMs = Double(clock() - t0) / 1e6
t0 = clock()
_ = ContextLexicon.candidates(for: example, indexes: prebuilt, limit: 8, commonWords: common)
let indexedMs = Double(clock() - t0) / 1e6
print("INFO: 30k форм — перебор \(Int(bruteMs)) мс, готовый индекс \(String(format: "%.2f", indexedMs)) мс")
check("готовый индекс быстрее перебора", indexedMs < bruteMs)

print("\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
