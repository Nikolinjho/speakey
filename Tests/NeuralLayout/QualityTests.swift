import Foundation

enum QualityTests: DiagnosticSuite {
    static let name = "quality"
    static func run(_ t: DiagnosticTests) {
        t.check("Дополнительная ложная замена запрещает допуск", !Quality.ready(baselineFP: 0, assistedFP: 1, baselineRecall: 0.3, assistedRecall: 0.9))
        t.check("Прирост ровно пять пунктов разрешает допуск", Quality.ready(baselineFP: 2, assistedFP: 2, baselineRecall: 0.3, assistedRecall: 0.35))
        t.check("Малый прирост запрещает допуск", !Quality.ready(baselineFP: 0, assistedFP: 0, baselineRecall: 0.3, assistedRecall: 0.349))
        t.check("Семейство не пересекает выборки", !Quality.disjoint(calibration: ["hello"], holdout: ["hello", "world"]))
        t.check("Разные семейства допустимы", Quality.disjoint(calibration: ["hello"], holdout: ["world"]))
        t.check("Валидный короткий префикс не делает неверную замену верной", !Quality.correct(target: "hello", result: "руддщ"))
        t.check("Неверная замена префикса не считается по одному направлению", !Quality.correct(target: "привет", result: "приеет"))
        let sha = String(repeating: "a", count: 64)
        let basicJSON = "{\"modelSHA256\":\"\(sha)\",\"enabled\":false,\"minimumScore\":0.95,\"minimumMargin\":0.5,\"policyVersion\":\"rightlayout-live-policy-v1\",\"fixturesSHA256\":\"\(sha)\",\"splitsSHA256\":\"\(sha)\",\"detectorSHA256\":\"\(sha)\",\"reason\":\"recall-gain-below-0.05\"}"
        let baseline = "{\"correctTokens\":2000,\"wrongTokens\":200,\"truePositives\":100,\"falsePositives\":0,\"adverseWrongConversions\":0,\"additionalFalseConversions\":0}"
        let metrics = "{\"baseline\":\(baseline),\"assisted\":\(baseline)}"
        let json = String(basicJSON.dropLast()) + ",\"calibration\":\(metrics),\"holdout\":\(metrics)}"
        t.check("Выключенный валидный профиль загружается", NeuralLayoutProfile.load(Data(json.utf8), modelSHA256: sha) != nil)
        t.check("Другая модель отклоняет профиль", NeuralLayoutProfile.load(Data(json.utf8), modelSHA256: String(repeating: "b", count: 64)) == nil)
        t.check("Другая версия policy отклоняет профиль", NeuralLayoutProfile.load(Data(json.replacingOccurrences(of: "policy-v1", with: "policy-v2").utf8), modelSHA256: sha) == nil)
        let enabledRefusal = json.replacingOccurrences(of: "\"enabled\":false", with: "\"enabled\":true")
        t.check("Включённый профиль с причиной отказа отклоняется", NeuralLayoutProfile.load(Data(enabledRefusal.utf8), modelSHA256: sha) == nil)
        let badMetrics = basicJSON.replacingOccurrences(of: "\"enabled\":false", with: "\"enabled\":true").replacingOccurrences(of: "recall-gain-below-0.05", with: "holdout-criteria-met")
        t.check("Допуск без проверенных метрик отклоняется", NeuralLayoutProfile.load(Data(badMetrics.utf8), modelSHA256: sha) == nil)
        let enabledBadMetrics = enabledRefusal.replacingOccurrences(of: "recall-gain-below-0.05", with: "holdout-criteria-met")
        t.check("Профиль без прироста recall отклоняется", NeuralLayoutProfile.load(Data(enabledBadMetrics.utf8), modelSHA256: sha) == nil)
        let validEnabled = enabledBadMetrics.replacingOccurrences(of: "\"assisted\":\(baseline)", with: "\"assisted\":\(baseline.replacingOccurrences(of: "\"truePositives\":100", with: "\"truePositives\":110"))")
        t.check("Проверенные метрики разрешают включённый профиль", NeuralLayoutProfile.load(Data(validEnabled.utf8), modelSHA256: sha)?.enabled == true)
        t.check("Недостаточный holdout отклоняется", NeuralLayoutProfile.load(Data(validEnabled.replacingOccurrences(of: "\"correctTokens\":2000", with: "\"correctTokens\":1999").utf8), modelSHA256: sha) == nil)
        let extraFP = validEnabled.replacingOccurrences(of: "\"additionalFalseConversions\":0", with: "\"additionalFalseConversions\":1")
        t.check("Новые ложные замены отклоняют профиль", NeuralLayoutProfile.load(Data(extraFP.utf8), modelSHA256: sha) == nil)
        t.check("Переполнение счётчиков отклоняется без падения", NeuralLayoutProfile.load(Data(validEnabled.replacingOccurrences(of: "\"correctTokens\":2000", with: "\"correctTokens\":\(Int.max)").utf8), modelSHA256: sha) == nil)
        t.check("Повреждённый профиль отклоняется", NeuralLayoutProfile.load(Data("{}".utf8), modelSHA256: sha) == nil)
        for token in ["hello", "привет", "ghbdtn", "ghbdtn!", "реьд", "foo_bar"] {
            t.check("Однородный поддерживаемый токен: \(token)", NeuralLayoutToken.assistanceSupported(token))
        }
        for token in ["helloмир", "hello world", "😀hello", "שלום", "", "hello\n", "1234"] {
            t.check("Неподдерживаемый токен: \(token.debugDescription)", !NeuralLayoutToken.assistanceSupported(token))
        }
        let source = try! String(contentsOfFile: "Tests/NeuralLayout/quality-source.jsonl", encoding: .utf8)
        let rows = source.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
        for (word, expected) in [("ghbdtn", "ru"), ("руддщ", "en"), ("реьд", "en"), ("дд", "keep"), ("ll", "keep")] {
            t.check("Фиксированная метка \(word) = \(expected)", rows.first { $0["text"] == word }?["expected"] == expected)
        }
        let bundledData = try! Data(contentsOf: URL(fileURLWithPath: "Resources/RightLayout/profile.json"))
        let bundled = try! JSONDecoder().decode(NeuralLayoutProfile.self, from: bundledData)
        t.check("Поставляемый профиль проходит runtime-валидацию", NeuralLayoutProfile.load(bundledData, modelSHA256: bundled.modelSHA256) != nil)
        for word in ["npm", "Nuxt", "kubectl"] {
            t.check("Правильная латиница в русской фразе: \(word)", rows.first { $0["text"] == word }?["context"]?.contains(word) == true)
        }
    }
}
