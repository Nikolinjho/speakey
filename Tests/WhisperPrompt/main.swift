import Foundation

var checks = 0, failures = 0
func check(_ name: String, _ value: Bool) {
    checks += 1
    if !value { failures += 1 }
    print("\(value ? "PASS" : "FAIL"): \(name)")
}

let old = WhisperPrompt.wordsPhrase(contextWords: [], hintWords: ["a", "b"], language: "ru", maxChars: 600)
check("Пустой контекст даёт прежнюю фразу", old == " Часто встречаются слова: a, b.")
check("Пустые списки дают пустую фразу",
      WhisperPrompt.wordsPhrase(contextWords: [], hintWords: [], language: "ru", maxChars: 600) == "")

let merged = WhisperPrompt.wordsPhrase(contextWords: ["DPR", "подборок"], hintWords: ["Speakey", "dpr"], language: "ru", maxChars: 600)
check("Контекст первый, дубли без учёта регистра убраны", merged == " Часто встречаются слова: DPR, подборок, Speakey.")

let en = WhisperPrompt.wordsPhrase(contextWords: ["DPR"], hintWords: [], language: "en", maxChars: 600)
check("Английский префикс", en.hasPrefix(" Words that often come up: "))

let long = (0..<200).map { "слово\($0)длинное" }
let phrase = WhisperPrompt.wordsPhrase(contextWords: long, hintWords: ["Speakey"], language: "ru", maxChars: 600 - WhisperPrompt.ru.count)
check("Затравка не длиннее 600", (WhisperPrompt.ru + phrase).count <= 600)
check("Фраза начинается с первого слова контекста", phrase.hasPrefix(" Часто встречаются слова: слово0длинное"))
check("Фраза не пустая и закрыта точкой", !phrase.isEmpty && phrase.hasSuffix("."))
check("Хвост словаря отброшен раньше контекста", !phrase.contains("Speakey"))

let tight = WhisperPrompt.wordsPhrase(contextWords: ["aaaa", "bbbb"], hintWords: ["cccc"], language: "ru", maxChars: 40)
check("Бюджет соблюдён при малом лимите", tight.count <= 40)
check("Ничего не влезло: пусто",
      WhisperPrompt.wordsPhrase(contextWords: ["слово"], hintWords: [], language: "ru", maxChars: 5) == "")

let cleaned = WhisperPrompt.wordsPhrase(contextWords: ["a«b:c;", "»"], hintWords: [], language: "ru", maxChars: 600)
check("Спецсимволы вырезаются", cleaned == " Часто встречаются слова: abc.")

let tooLong = String(repeating: "я", count: 41)
let ok40 = String(repeating: "я", count: 40)
let limited = WhisperPrompt.wordsPhrase(contextWords: [tooLong, ok40], hintWords: [], language: "ru", maxChars: 600)
check("Слово длиннее 40 символов отброшено", limited == " Часто встречаются слова: \(ok40).")

let echoPrompt = WhisperPrompt.ru + merged
check("stripEcho срезает эхо новой фразы целиком",
      WhisperPrompt.stripEcho(echoPrompt + " текст", prompt: echoPrompt).text == "текст")

check("Пустой контекст: слова словаря как есть",
      WhisperPrompt.wordsPhrase(contextWords: [], hintWords: ["Speakey", "speakey", "a:b"], language: "ru", maxChars: 600)
        == " Часто встречаются слова: Speakey, speakey, a:b.")
check("Контекст чистится от «",
      WhisperPrompt.wordsPhrase(contextWords: ["x«y"], hintWords: [], language: "ru", maxChars: 600).contains("xy"))
let hint41 = String(repeating: "я", count: 41)
check("Длинное слово словаря сохраняется",
      WhisperPrompt.wordsPhrase(contextWords: [], hintWords: [hint41], language: "ru", maxChars: 600).contains(hint41))

print("\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
