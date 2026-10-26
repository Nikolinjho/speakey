import Foundation

struct DetectorCase: Decodable {
    let name: String
    let word: String
    let decision: String
}

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "baseline" else {
    fputs("Ожидался набор baseline и путь к данным\n", stderr)
    exit(2)
}
// Аргументный домен хранится в памяти и перекрывает настройки пользователя.
UserDefaults.standard.setVolatileDomain([
    "ignoredWords": [String](), "forceSwapWords": [String](), "learnedWords": [String](),
    "appExceptionModes": [String: String](), "appForcedLayouts": [String: String](),
    "seededDefaultApps": [String](), "didSeedExcExamples": true,
    "didSeedExcVkLatin": true, "didUnseedExcSpotlight": true
], forName: UserDefaults.argumentDomain)
let tests = DiagnosticTests()
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let cases = try JSONDecoder().decode([DetectorCase].self, from: data)
    guard !cases.isEmpty else { exit(2) }
    let resourceDirectory = ProcessInfo.processInfo.environment["KEYBOOP_DATA_DIR"] ?? ""
    for name in ["words_ru", "words_en", "trigrams_ru", "trigrams_en"] {
        let resource = URL(fileURLWithPath: resourceDirectory).appendingPathComponent("\(name).json")
        let loaded: Bool
        if let data = try? Data(contentsOf: resource) {
            if name.hasPrefix("words_") {
                loaded = (try? JSONDecoder().decode([String].self, from: data)).map { !$0.isEmpty } ?? false
            } else {
                loaded = (try? JSONDecoder().decode([String: Double].self, from: data)).map { !$0.isEmpty } ?? false
            }
        } else {
            loaded = false
        }
        tests.check("Ресурс \(name).json существует и содержит данные", loaded)
    }
    for item in cases {
        let expected: SwapDecision
        switch item.decision {
        case "keep": expected = .keep
        case "ru": expected = .convert(toCyrillic: true)
        case "en": expected = .convert(toCyrillic: false)
        default: fputs("Неизвестное ожидание: \(item.decision)\n", stderr); exit(2)
        }
        tests.check(item.name, LayoutDetector.decide(word: item.word, exceptions: .shared) == expected)
    }
} catch {
    fputs("Не удалось прочитать набор: \(error)\n", stderr)
    exit(2)
}
tests.finish()
