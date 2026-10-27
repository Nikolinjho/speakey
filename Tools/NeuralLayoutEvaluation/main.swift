import Foundation
import CryptoKit

struct Fixture: Codable {
    let family: String
    let text: String
    let expected: String
    let language: String
    let kind: String
    let source: String
    let license: String
}
struct Split: Codable {
    let version: Int
    let algorithm: String
    let fixturesSHA256: String
    let calibration: [String]
    let holdout: [String]
    let provenance: [String: String]
}
struct Event {
    let index: Int
    let result: String
    let score: Double
    let margin: Double
}
struct Sample {
    let family: String
    let text: String
    let target: String
    let wrong: Bool
    let baseline: Event?
    let candidates: [Event]
    let boundary: String
    let raw: Event?
}
struct Metrics: Codable, Equatable {
    var correctTokens = 0
    var wrongTokens = 0
    var truePositives = 0
    var falsePositives = 0
    var adverseWrongConversions = 0
    var additionalFalseConversions = 0
    var abstentions = 0
    var firstDecisionLetters: [String: Int] = [:]
    var recall: Double { wrongTokens == 0 ? 0 : Double(truePositives) / Double(wrongTokens) }
}
struct Evaluation: Codable, Equatable {
    let baseline: Metrics
    let assisted: Metrics
    let rawModel: Metrics
    let boundaryDetector: Metrics
}
struct ProfileReport: Codable, Equatable {
    let policyVersion: String
    let modelSHA256: String
    let modelID: String
    let fixturesSHA256: String
    let splitsSHA256: String
    let detectorSHA256: String
    let enabled: Bool
    let reason: String
    let minimumScore: Double
    let minimumMargin: Double
    let calibration: Evaluation
    let holdout: Evaluation
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func read(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "Quality", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func metric(_ samples: [Sample], choose: (Sample) -> Event?) -> Metrics {
    var value = Metrics()
    for sample in samples {
        if sample.wrong { value.wrongTokens += 1 } else { value.correctTokens += 1 }
        guard let event = choose(sample) else { value.abstentions += 1; continue }
        value.firstDecisionLetters[String(event.index), default: 0] += 1
        if sample.wrong {
            if Quality.correct(target: sample.target, result: event.result) { value.truePositives += 1 }
            else { value.adverseWrongConversions += 1 }
        } else { value.falsePositives += 1 }
        let bad = event.result != sample.target
        let baselineBad = sample.baseline.map { $0.result != sample.target } ?? false
        if bad && !baselineBad { value.additionalFalseConversions += 1 }
    }
    return value
}
func chosen(_ sample: Sample, score: Double, margin: Double) -> Event? {
    // Правило срабатывает первым на том же префиксе, как в runtime.
    for event in sample.candidates where event.score >= score && event.margin >= margin {
        if let baseline = sample.baseline, baseline.index <= event.index { return baseline }
        return event
    }
    return sample.baseline
}
func evaluate(_ samples: [Sample], score: Double, margin: Double) -> Evaluation {
    Evaluation(baseline: metric(samples) { $0.baseline },
               assisted: metric(samples) { chosen($0, score: score, margin: margin) },
               rawModel: metric(samples) { $0.raw },
               boundaryDetector: metric(samples) { s in s.boundary == s.text ? nil : Event(index: s.text.count, result: s.boundary, score: 0, margin: 0) })
}

let policyVersion = NeuralLayoutProfile.policyVersion
do {
    let verify = CommandLine.arguments.contains("--verify")
    let fixtureData = try read("Tests/NeuralLayout/quality-source.jsonl")
    let splitData = try read("Tests/NeuralLayout/quality-splits.json")
    let split = try JSONDecoder().decode(Split.self, from: splitData)
    let fixtures = try fixtureData.split(separator: 10).map { try JSONDecoder().decode(Fixture.self, from: Data($0)) }
    let calibration = Set(split.calibration), holdout = Set(split.holdout)
    try require(split.version == 1 && split.algorithm == "sha256-first32be-mod10-less-than7", "Неизвестный алгоритм разделения")
    try require(Quality.disjoint(calibration: calibration, holdout: holdout), "Пересечение семейств")
    try require(calibration.union(holdout) == Set(fixtures.map(\.family)), "Неверный набор семейств")
    try require(digest(fixtureData) == split.fixturesSHA256, "Изменились замороженные fixtures")
    for (path, sha) in split.provenance { try require(digest(try read(path)) == sha, "Изменился источник \(path)") }
    try require(split.provenance.count == 2, "Нет происхождения словарей")
    for row in fixtures {
        let family = row.family
        let bucket = UInt32(digest(Data(family.utf8)).prefix(8), radix: 16)! % 10
        try require(calibration.contains(family) == (bucket < 7), "Нестабильное разделение \(family)")
        try require(!row.source.isEmpty && ["MIT", "project"].contains(row.license), "Нет лицензии")
        try require(row.family == row.text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "!.")), "Ненормализованное семейство")
    }
    let modelData = try read("Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel")
    let sha = digest(modelData)
    let manifest = try JSONSerialization.jsonObject(with: read("Resources/RightLayout/model.json")) as! [String: Any]
    try require(sha == manifest["sha256"] as? String, "SHA модели не совпадает")
    let model = try RightLayoutModel(modelURL: URL(fileURLWithPath: CommandLine.arguments[1]))
    let domain = "keyboop-quality-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let exceptions = ExceptionStore(defaults: defaults)
    let permissive = try NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: 0, minimumMargin: 0)
    var cache: [String: NeuralLayoutScores] = [:]
    func scores(_ text: String) throws -> NeuralLayoutScores {
        if let hit = cache[text] { return hit }
        let result = try model.predict(text)
        cache[text] = result
        return result
    }
    func converted(_ text: String, direction: Bool) -> String? {
        Keymap.liveConvert(text, toCyrillic: direction, isValidTarget: { LayoutData.shared.wordsRu.contains($0.lowercased()) })
    }
    func outcome(_ text: String, prefix: String, result: String, direction: Bool) -> String {
        // После переключения остальные физические клавиши читаются целевой раскладкой.
        result + Keymap.convert(String(text.dropFirst(prefix.count)), toCyrillic: direction)
    }
    func sample(_ row: Fixture, text: String, target: String, wrong: Bool) throws -> Sample {
        var baseline: Event?, raw: Event?
        var candidates: [Event] = []
        if text.count >= 4 {
            for index in 4...min(16, text.count) {
                let prefix = String(text.prefix(index))
                if baseline == nil, case .convert(let direction) = LayoutDetector.liveDecide(word: prefix, exceptions: exceptions),
                   let result = converted(prefix, direction: direction) {
                    baseline = Event(index: index, result: outcome(text, prefix: prefix, result: result, direction: direction), score: 0, margin: 0)
                }
                let values = try scores(prefix)
                let winner = NeuralLayoutClass.allCases.max { values[$0] < values[$1] }!
                if raw == nil, winner == .ruFromEn || winner == .enFromRu {
                    let direction = winner == .ruFromEn
                    raw = Event(index: index, result: outcome(text, prefix: prefix, result: Keymap.convert(prefix, toCyrillic: direction), direction: direction), score: values[winner], margin: 0)
                }
                let admission = NeuralLayoutAdmission(mode: .assist, modelSHA256: sha, profile: permissive, fresh: true,
                    block: !NeuralLayoutToken.assistanceSupported(prefix) ? .unsupported : (LayoutDetector.neuralRuleBlock(word: prefix, exceptions: exceptions) ? .rule : nil),
                    wordLength: prefix.count, sourceCyrillic: prefix.hasCyrillic)
                if case .propose(let direction) = NeuralLayoutPolicy.evaluate(scores: values, admission: admission),
                   let result = converted(prefix, direction: direction) {
                    let label: NeuralLayoutClass = direction ? .ruFromEn : .enFromRu
                    let runner = NeuralLayoutClass.allCases.filter { $0 != label }.map { values[$0] }.max()!
                    candidates.append(Event(index: index, result: outcome(text, prefix: prefix, result: result, direction: direction), score: values[label], margin: values[label] - runner))
                }
            }
        }
        var boundary = text
        if case .convert(let direction) = LayoutDetector.decide(word: text, exceptions: exceptions) {
            boundary = Keymap.smartConvert(text, toCyrillic: direction, isValidTarget: { LayoutData.shared.wordsRu.contains($0.lowercased()) })
        }
        return Sample(family: row.family, text: text, target: target, wrong: wrong, baseline: baseline, candidates: candidates, boundary: boundary, raw: raw)
    }
    var samples: [Sample] = []
    for row in fixtures {
        let explicitWrong = row.expected != "keep"
        let target = explicitWrong ? Keymap.convert(row.text, toCyrillic: row.expected == "ru") : row.text
        samples.append(try sample(row, text: row.text, target: target, wrong: explicitWrong))
        // Короткие, смешанные и словарно-неоднозначные варианты не объявляем ошибкой.
        if row.kind == "dictionary", row.text.count >= 4 {
            let wrong = Keymap.convert(row.text, toCyrillic: row.language == "en")
            if wrong != row.text && !LayoutData.shared.wordsEn.contains(wrong.lowercased()) && !LayoutData.shared.wordsRu.contains(wrong.lowercased()) {
                samples.append(try sample(row, text: wrong, target: row.text, wrong: true))
            }
        }
    }
    let cal = samples.filter { calibration.contains($0.family) }
    let held = samples.filter { holdout.contains($0.family) }
    try require(held.filter { !$0.wrong }.count >= 2000 && held.filter(\.wrong).count >= 200, "Недостаточный объём holdout")
    for language in [false, true] { try require(held.filter { $0.wrong && $0.target.hasCyrillic == language }.count >= 100, "Недостаточно ошибок одного языка") }
    print("CPU прогнозов уникальных префиксов: \(cache.count), calibration: \(cal.count), holdout: \(held.count)")
    let baseline = metric(cal) { $0.baseline }
    var best: (score: Double, margin: Double, recall: Double)?
    // Scores и admission закэшированы один раз. Меняются только два сравнения порогов policy.
    for scoreInt in 50...95 {
        for marginInt in 5...50 {
            let score = Double(scoreInt) / 100, margin = Double(marginInt) / 100
            let value = metric(cal) { chosen($0, score: score, margin: margin) }
            guard value.falsePositives <= baseline.falsePositives && value.additionalFalseConversions == 0 else { continue }
            if best == nil || value.recall > best!.recall || (value.recall == best!.recall && (score > best!.score || (score == best!.score && margin > best!.margin))) {
                best = (score, margin, value.recall)
            }
        }
    }
    let threshold = best ?? (score: 0.95, margin: 0.50, recall: 0)
    let calResult = evaluate(cal, score: threshold.score, margin: threshold.margin)
    let heldResult = evaluate(held, score: threshold.score, margin: threshold.margin)
    let ready = best != nil && heldResult.assisted.additionalFalseConversions == 0 && Quality.ready(baselineFP: heldResult.baseline.falsePositives, assistedFP: heldResult.assisted.falsePositives, baselineRecall: heldResult.baseline.recall, assistedRecall: heldResult.assisted.recall)
    let reason = ready ? "holdout-criteria-met" : (best == nil ? "no-safe-calibration-profile" : (heldResult.assisted.additionalFalseConversions > 0 ? "additional-false-conversions" : "recall-gain-below-0.05"))
    let detectorPaths = ["LayoutDetector", "NeuralLayoutPolicy", "NeuralLayoutTypes", "Keymap", "DynamicKeymap", "ExtraWords", "LayoutData", "ExceptionStore"]
    var detectorData = Data()
    for name in detectorPaths { detectorData.append(try read("Sources/Keyboop/\(name).swift")) }
    for path in ["Sources/Keyboop/Resources/trigrams_ru.json", "Sources/Keyboop/Resources/trigrams_en.json"] { detectorData.append(try read(path)) }
    let report = ProfileReport(policyVersion: policyVersion, modelSHA256: sha, modelID: manifest["modelID"] as! String,
        fixturesSHA256: digest(fixtureData), splitsSHA256: digest(splitData), detectorSHA256: digest(detectorData),
        enabled: ready, reason: reason, minimumScore: threshold.score, minimumMargin: threshold.margin, calibration: calResult, holdout: heldResult)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let path = "Resources/RightLayout/profile.json"
    if verify {
        let previous = try JSONDecoder().decode(ProfileReport.self, from: read(path))
        try require(previous == report, "Профиль не соответствует воспроизведённой оценке")
        try require(try read(path) == read("Sources/Keyboop/Resources/RightLayout/profile.json"), "Копия профиля отличается")
    } else {
        let data = try encoder.encode(report) + Data([10])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try data.write(to: URL(fileURLWithPath: "Sources/Keyboop/Resources/RightLayout/profile.json"), options: .atomic)
        func line(_ name: String, _ m: Metrics) -> String {
            "| \(name) | \(m.falsePositives) | \(m.truePositives)/\(m.wrongTokens) (\(String(format: "%.4f", m.recall))) | \(m.abstentions) | \(m.adverseWrongConversions) |"
        }
        let text = """
        # Оценка RightLayout

        Замороженные данные: keyswitcher (MIT, см. THIRD_PARTY.md) и проектные примеры. Из каждого словаря выбраны 4200 слов длиной 4–16 букв по возрастанию SHA256 нормализованного слова, добавлены 19 проектных примеров. Личный журнал не используется. Для npm, Nuxt и kubectl сохранён русский контекст в метаданных. В модель поступает только токен, как в runtime. Семейство – нормализованный исходный токен. SHA256 первых четырёх байт modulo 10: 0–6 calibration, 7–9 holdout. Префиксы и ошибочные раскладки получены после разделения. Подбор 2116 пар порогов выполняется только на calibration, holdout проверяет одну выбранную пару.

        Модель: `\(report.modelID)`, CPU, SHA256 `\(sha)`.
        Policy: `\(policyVersion)`, SHA детектора `\(report.detectorSHA256)`.
        Fixtures SHA256: `\(report.fixturesSHA256)`.
        Split SHA256: `\(report.splitsSHA256)`.
        Пороги: score ≥ \(threshold.score), margin ≥ \(threshold.margin).
        Профиль: enabled=\(ready), причина `\(reason)`.

        Holdout: \(heldResult.baseline.correctTokens) корректных и \(heldResult.baseline.wrongTokens) ошибочных токенов обоих языков.

        | Holdout, режим | Ложные замены корректных | Recall (live: ранний, boundary: полный) | Воздержания | Неверная замена ошибочного |
        |---|---:|---:|---:|---:|
        \(line("Текущий live detector", heldResult.baseline))
        \(line("Live detector + policy", heldResult.assisted))
        \(line("Сырой argmax модели", heldResult.rawModel))
        \(line("Отдельный boundary detector", heldResult.boundaryDetector))

        Boundary recall измерен по полному слову и не является ранним recall. Raw argmax – описательная статистика без admission, score не калиброванная вероятность. Префиксы live-пути: 4–16 символов. Первое действие фиксируется, остаток физических клавиш преобразуется в его раскладку. Успех требует полного совпадения с целевым токеном, направление само по себе недостаточно. Новых ложных действий относительно baseline: \(heldResult.assisted.additionalFalseConversions). Распределения первого момента решения и calibration-метрики сохранены в profile.json.

        Для сравнения используются реальные liveDecide, neuralRuleBlock, NeuralLayoutPolicy и Keymap.liveConvert, изолированный ExceptionStore без пользовательских исключений. После кэширования прогнозов и admission перебор применяет эквивалентные два сравнения score/margin. При равном recall выбирается больший score, затем margin. Если безопасного calibration-профиля нет, пара 0.95/0.50 служит только диагностике и профиль выключен.

        Короткие дд/ll включены в keep-примеры. Явные ошибки ghbdtn/руддщ/реьд размечены как ru/en/en. Метки исправлены до финальной фиксации данных как ошибки аннотации. Пороги и алгоритм подбора после инженерного прогона не менялись. Смешанные скрипты, неизвестные символы и пробелы запрещены общим NeuralLayoutToken.assistanceSupported, как на пути автоматического предложения. Ошибочные производные словарных коллизий исключены до оценки без изменения split. Словарь содержит редкие слова и формы, поэтому набор не моделирует частотность живого ввода. Нулевое число новых FP на этом holdout не обещает нулевых FP вне него. Профиль не включает пользовательский assist автоматически.

        Воспроизведение: `bash scripts/test-neural-layout.sh quality && bash scripts/evaluate-neural-layout.sh --verify`.
        """
        try Data((text + "\n").utf8).write(to: URL(fileURLWithPath: "docs/development/rightlayout-quality.md"), options: .atomic)
    }
    print("Профиль enabled=\(ready), \(reason); FP \(heldResult.baseline.falsePositives) → \(heldResult.assisted.falsePositives), early recall \(heldResult.baseline.recall) → \(heldResult.assisted.recall); verify=\(verify)")
} catch {
    fputs("Ошибка оценки: \(error.localizedDescription)\n", stderr)
    exit(1)
}
