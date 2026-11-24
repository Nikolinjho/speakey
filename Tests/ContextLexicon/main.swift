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

print("\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
