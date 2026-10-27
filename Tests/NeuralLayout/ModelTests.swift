import CoreML
import Foundation

enum ModelTests: DiagnosticSuite {
    static let name = "model"

    static func run(_ t: DiagnosticTests) {
        func rejects(_ name: String, as expected: NeuralLayoutError, _ action: () throws -> Void) {
            do {
                try action()
                t.check(name, false)
            } catch let error as NeuralLayoutError {
                t.check(name, error == expected)
            } catch {
                t.check("\(name): нетипизированная ошибка \(error)", false)
            }
        }
        do {
            let scores = try NeuralLayoutScores(logits: [10000, 9999, 0, 0, 0, 0, 0, 0, 0])
            t.check("Softmax конечен", scores.values.allSatisfy { $0.isFinite })
            t.check("Сумма оценок равна единице", abs(scores.values.reduce(0, +) - 1) < 0.000001)
            t.check("Все девять классов сохранены", scores.values.count == 9)
            t.check("Разница больших логитов сохранена", abs(scores[.ru] - 0.7310585786) < 0.000001)
            let uniform = try NeuralLayoutScores(logits: Array(repeating: -10000, count: 9))
            t.check("Равные логиты дают равные оценки", uniform.values.allSatisfy { abs($0 - 1.0 / 9) < 0.000001 })
            t.check("Порядок классов совпадает с моделью", NeuralLayoutClass.allCases == [.ru, .en, .he, .ruFromEn, .heFromEn, .enFromRu, .enFromHe, .heFromRu, .ruFromHe])
            t.check("Режимы сохраняют строковый контракт", NeuralLayoutMode.allCases.map(\.rawValue) == ["off", "observe", "assist"])

            let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890 -=[]\\;',./`!@#$%^&*()_+{}|:\"<>?~"
                + "абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
                + "אבגדהוזחטיכלמנסעפצקרשתךםןףץ"
            for (index, character) in alphabet.enumerated() where character != " " {
                let ids = try RightLayoutTokenizer.encode(String(character))
                t.check("Индекс символа \(character) совпадает с исходным алфавитом", ids == [Int32(index + 1)] + Array(repeating: 0, count: 19))
            }
            let lower = try RightLayoutTokenizer.encode("a")
            let upper = try RightLayoutTokenizer.encode("A")
            t.check("Регистр не нормализуется", lower[0] != upper[0])
            let full = try RightLayoutTokenizer.encode(String(repeating: "z", count: 20))
            t.check("Двадцатый символ сохраняется", full == Array(repeating: 26, count: 20))
            let unknownOnly = try RightLayoutTokenizer.encode("🙂")
            t.check("Полностью неизвестный токен кодируется нулями", unknownOnly == Array(repeating: 0, count: 20))
            let unknown = try RightLayoutTokenizer.encode("a🙂")
            t.check("Неизвестный символ кодируется нулём", unknown[0] == 1 && unknown.dropFirst().allSatisfy { $0 == 0 })
        } catch {
            t.check("Валидные оценки и токены: \(error)", false)
        }
        for logits: [Double] in [[], [1], Array(repeating: 0, count: 10), [.nan] + Array(repeating: 0, count: 8), [.infinity] + Array(repeating: 0, count: 8), [-.infinity] + Array(repeating: 0, count: 8)] {
            rejects("Некорректные логиты отклонены", as: .invalidOutput) { _ = try NeuralLayoutScores(logits: logits) }
        }
        for word in ["", String(repeating: "a", count: 21), "a b", " hello", "a\tb", "a\nb", "a\u{0000}b", "a\u{007F}b", "a\u{00A0}b", "a\u{200B}b"] {
            rejects("Некорректный токен \(word.debugDescription) отклонён", as: .invalidToken) { _ = try RightLayoutTokenizer.encode(word) }
        }
        do {
            try RightLayoutModel.validateArray(type: .multiArray, dataType: .float32, shape: [1, 20], isInput: true)
            try RightLayoutModel.validateArray(type: .multiArray, dataType: .float32, shape: [], isInput: false, allowUnspecifiedShape: true)
            t.check("Объявленная schema закреплённой модели принимается", true)
        } catch {
            t.check("Объявленная schema закреплённой модели: \(error)", false)
        }
        for shape in [[3, 3], [1, 8], [], [1, 1, 9]] {
            rejects("Неизвестная форма логитов \(shape) отклонена", as: .invalidOutput) {
                try RightLayoutModel.validateArray(type: .multiArray, dataType: .float32, shape: shape, isInput: false)
            }
        }
        rejects("Вход неверного типа отклонён", as: .invalidOutput) {
            try RightLayoutModel.validateArray(type: .multiArray, dataType: .double, shape: [1, 20], isInput: true)
        }
        rejects("Вход неверной формы отклонён", as: .invalidOutput) {
            try RightLayoutModel.validateArray(type: .multiArray, dataType: .int32, shape: [20], isInput: true)
        }
        rejects("Выход неверного типа отклонён", as: .invalidOutput) {
            try RightLayoutModel.validateArray(type: .string, dataType: nil, shape: [9], isInput: false)
        }
        rejects("Целочисленные логиты отклонены", as: .invalidOutput) {
            try RightLayoutModel.validateArray(type: .multiArray, dataType: .int32, shape: [9], isInput: false)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        rejects("Отсутствующая модель возвращает unavailable", as: .unavailable) { _ = try RightLayoutModel(modelURL: temporary) }
        do {
            try Data("corrupt".utf8).write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            rejects("Повреждённая модель возвращает unavailable", as: .unavailable) { _ = try RightLayoutModel(modelURL: temporary) }
        } catch {
            t.check("Создание повреждённого ресурса: \(error)", false)
        }
        guard CommandLine.arguments.count > 2 else {
            t.check("Путь настоящей скомпилированной модели передан", false)
            return
        }
        do {
            let backend: NeuralLayoutBackend = try RightLayoutModel(modelURL: URL(fileURLWithPath: CommandLine.arguments[2]))
            for (word, expected) in [("ghbdtn", NeuralLayoutClass.ruFromEn), ("руддщ", .enFromRu)] {
                let scores = try backend.predict(word)
                let winner = NeuralLayoutClass.allCases.max { scores[$0] < scores[$1] }
                t.check("Настоящая модель: \(word) -> \(expected)", winner == expected)
                t.check("Настоящая модель: вероятности нормализованы", abs(scores.values.reduce(0, +) - 1) < 0.000001)
            }
            rejects("Backend отклоняет длинный ввод", as: .invalidToken) { _ = try backend.predict(String(repeating: "a", count: 21)) }
            let limitation = try backend.predict("реьд")
            let winner = NeuralLayoutClass.allCases.max { limitation[$0] < limitation[$1] }
            print("ОГРАНИЧЕНИЕ МОДЕЛИ: реьд, ожидается enFromRu, получено \(String(describing: winner)), оценки \(limitation.values)")
        } catch {
            t.check("Настоящие веса загружаются и выполняют прогноз: \(error)", false)
        }
    }
}
