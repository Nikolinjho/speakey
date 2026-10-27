import Foundation

enum PolicyTests: DiagnosticSuite {
    static let name = "policy"
    static let sha = String(repeating: "a", count: 64)

    static func run(_ t: DiagnosticTests) {
        let profile = try! NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: 0.7, minimumMargin: 0.3)
        func admission(mode: NeuralLayoutMode = .assist, profile candidate: NeuralLayoutProfile? = profile,
                       fresh: Bool = true, block: NeuralLayoutBlock? = nil, length: Int = 6,
                       cyrillic: Bool = false, modelSHA: String = sha) -> NeuralLayoutAdmission {
            NeuralLayoutAdmission(mode: mode, modelSHA256: modelSHA, profile: candidate, fresh: fresh,
                                  block: block, wordLength: length, sourceCyrillic: cyrillic)
        }
        func scores(_ winner: NeuralLayoutClass, runner: NeuralLayoutClass? = nil) -> NeuralLayoutScores {
            var logits = Array(repeating: -10.0, count: 9)
            logits[winner.rawValue] = 5
            if let runner { logits[runner.rawValue] = 4.9 }
            return try! NeuralLayoutScores(logits: logits)
        }
        let strong = scores(.ruFromEn)
        for block in [NeuralLayoutBlock.disabled, .unavailable, .profile, .stale, .length, .unsupported,
                      .confidence, .app, .developer, .secureInput, .modifiers, .editing, .syntheticFlight,
                      .undo, .rule, .resonance, .keymap] {
            t.check("Явный запрет сильнее высокого score: \(block)", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(block: block)) == .blocked(block))
        }
        t.check("Выключенный режим сильнее запрета приложения", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(mode: .off, block: .app)) == .blocked(.disabled))
        t.check("Observe не предлагает замену даже при hard-block", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(mode: .observe, block: .app)) == .observe)
        t.check("Запрет undo сильнее устаревшего результата", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(fresh: false, block: .undo)) == .blocked(.undo))
        t.check("Hard-block проверяется до профиля", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(profile: nil, block: .rule)) == .blocked(.rule))
        let disabled = try! NeuralLayoutProfile(modelSHA256: sha, enabled: false, minimumScore: 0.7, minimumMargin: 0.3)
        for candidate in [nil, disabled] as [NeuralLayoutProfile?] {
            t.check("Assist без активного профиля только наблюдает", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(profile: candidate)) == .observe)
        }
        t.check("SHA другой модели оставляет observe", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(modelSHA: String(repeating: "b", count: 64))) == .observe)
        t.check("Отсутствие профиля сильнее устаревания", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(profile: nil, fresh: false)) == .observe)
        t.check("Устаревание сильнее длины", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(fresh: false, length: 3)) == .blocked(.stale))
        for length in [0, 3, 17] {
            t.check("Недопустимая длина \(length)", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(length: length)) == .blocked(.length))
        }
        for length in [4, 16] {
            t.check("Граница длины \(length) допускает направление в русский", NeuralLayoutPolicy.evaluate(scores: strong, admission: admission(length: length)) == .propose(toCyrillic: true))
        }
        for label in NeuralLayoutClass.allCases {
            for sourceCyrillic in [false, true] {
                let expected: NeuralLayoutPolicyResult
                if label == (sourceCyrillic ? .enFromRu : .ruFromEn) {
                    expected = .propose(toCyrillic: !sourceCyrillic)
                } else if [.ru, .en, .ruFromEn, .enFromRu].contains(label) {
                    expected = .blocked(.confidence)
                } else {
                    expected = .blocked(.unsupported)
                }
                t.check("Победитель \(label), исходная кириллица \(sourceCyrillic)", NeuralLayoutPolicy.evaluate(scores: scores(label), admission: admission(cyrillic: sourceCyrillic)) == expected)
            }
        }
        for runner in NeuralLayoutClass.allCases where runner != .ruFromEn {
            t.check("Отрыв от каждого из восьми классов: \(runner)", NeuralLayoutPolicy.evaluate(scores: scores(.ruFromEn, runner: runner), admission: admission()) == .blocked(.confidence))
        }
        var moderateLogits = Array(repeating: -10.0, count: 9)
        moderateLogits[NeuralLayoutClass.ruFromEn.rawValue] = log(0.8)
        moderateLogits[NeuralLayoutClass.en.rawValue] = log(0.2)
        let moderate = try! NeuralLayoutScores(logits: moderateLogits)
        t.check("Score ниже 0,99 допускается порогами профиля", NeuralLayoutPolicy.evaluate(scores: moderate, admission: admission()) == .propose(toCyrillic: true))
        let marginProfile = try! NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: 0.4, minimumMargin: 0.3)
        t.check("Достаточный score не заменяет необходимый отрыв", NeuralLayoutPolicy.evaluate(scores: scores(.ruFromEn, runner: .en), admission: admission(profile: marginProfile)) == .blocked(.confidence))
        let uniform = try! NeuralLayoutScores(logits: Array(repeating: 0, count: 9))
        t.check("Недостаточный score отклоняется", NeuralLayoutPolicy.evaluate(scores: uniform, admission: admission()) == .blocked(.confidence))
        let permissive = try! NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: 0, minimumMargin: 0)
        t.check("Порог ноль не превращает нативный класс в предложение", NeuralLayoutPolicy.evaluate(scores: scores(.en), admission: admission(profile: permissive)) == .blocked(.confidence))
        for threshold in [-0.1, 1.1, Double.nan, Double.infinity] {
            t.check("Невалидный minimumScore \(threshold)", (try? NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: threshold, minimumMargin: 0.3)) == nil)
            t.check("Невалидный minimumMargin \(threshold)", (try? NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: 0.7, minimumMargin: threshold)) == nil)
        }
        for invalidSHA in ["", " ", "wrong", String(repeating: "z", count: 64)] {
            t.check("Невалидный SHA отклоняется", (try? NeuralLayoutProfile(modelSHA256: invalidSHA, enabled: true, minimumScore: 0.7, minimumMargin: 0.3)) == nil)
        }
        for (score, margin) in [(0.0, 0.0), (1.0, 1.0)] {
            let value = try! NeuralLayoutProfile(modelSHA256: sha, enabled: true, minimumScore: score, minimumMargin: margin)
            let data = try! JSONEncoder().encode(value)
            t.check("Граничные пороги проходят Codable", (try? JSONDecoder().decode(NeuralLayoutProfile.self, from: data))?.minimumMargin == margin)
        }
        let nonfiniteDecoder = JSONDecoder()
        nonfiniteDecoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for value in ["NaN", "Infinity", "-Infinity"] {
            let data = Data("{\"modelSHA256\":\"\(sha)\",\"enabled\":true,\"minimumScore\":\"\(value)\",\"minimumMargin\":0.3}".utf8)
            t.check("Декодирование не пропускает нечисловой порог: \(value)", (try? nonfiniteDecoder.decode(NeuralLayoutProfile.self, from: data)) == nil)
        }
        for json in [
            "{\"modelSHA256\":\"\(sha)\",\"enabled\":true,\"minimumScore\":-1,\"minimumMargin\":0.3}",
            "{\"modelSHA256\":\"\(sha)\",\"enabled\":true,\"minimumScore\":0.7,\"minimumMargin\":2}",
            "{\"modelSHA256\":\"\",\"enabled\":true,\"minimumScore\":0.7,\"minimumMargin\":0.3}"
        ] {
            t.check("Декодирование не обходит валидацию профиля", (try? JSONDecoder().decode(NeuralLayoutProfile.self, from: Data(json.utf8))) == nil)
        }
    }
}
