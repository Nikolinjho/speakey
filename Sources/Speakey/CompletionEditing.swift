import Foundation

/// Чистые правила редактирования. Индексы AX остаются в UTF16, текстовые границы — Character.
enum CompletionEditing {
    enum ChoiceDecision: Equatable { case pass, dismiss, select(Int), accept(Int) }

    static func usesUnicodeInsertion(bundleID: String, isElectron: Bool) -> Bool {
        isElectron || ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(bundleID)
    }

    static func hasTextOnCurrentLine(after: String) -> Bool {
        after.prefix(while: { !$0.isNewline }).unicodeScalars.contains {
            !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint
        }
    }

    static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || ["-", "_", "'", "’"].contains(character)
    }

    static func currentWord(_ raw: String, before: String) -> String {
        guard let last = before.last, isWord(last), let first = raw.first, isWord(first) else { return "" }
        return String(raw.prefix(while: isWord))
    }

    static func insertion(_ raw: String, before: String, after: String, continuingWord: Bool = false) -> String {
        if let left = before.last, let right = after.first, isWord(left), isWord(right) { return "" }
        var text = CompletionText.clean(raw, before: before, maxWords: 10)
        let right = before.last?.isWhitespace == true ? String(after.drop(while: { $0.isWhitespace })) : after
        let candidate = Array(text), suffix = Array(right)
        if !candidate.isEmpty, !suffix.isEmpty {
            for count in stride(from: min(candidate.count, suffix.count), through: 1, by: -1) {
                let start = candidate.count - count
                guard Array(candidate[start...]) == Array(suffix.prefix(count)) else { continue }
                // Совпавшая буква внутри слова не является повтором соседнего текста.
                if start > 0, isWord(candidate[start]), isWord(candidate[start - 1]) { continue }
                if count < suffix.count, isWord(suffix[count - 1]), isWord(suffix[count]) { continue }
                text = String(candidate.prefix(start)); break
            }
        }
        text = text.trimmingCharacters(in: .newlines)
        while text.last?.isWhitespace == true { text.removeLast() }
        if !continuingWord, let left = before.last, let first = text.first, isWord(left), isWord(first) { text = " " + text }
        if let last = text.last, let right = after.first, !last.isWhitespace, isWord(right) { text += " " }
        return text
    }

    static func selectionEligible(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        return !words.isEmpty && words.count <= 6 && text.utf16.count <= 120
            && !text.unicodeScalars.contains { CharacterSet.newlines.contains($0) || $0 == "\u{FFFC}" }
            && text.allSatisfy { isWord($0) || $0.isWhitespace }
            && text.contains(where: { $0.isLetter })
    }

    static func synonyms(_ raw: String, original: String) -> [String] {
        let clean = raw.components(separatedBy: "<|").first ?? raw
        let components = clean.components(separatedBy: CharacterSet(charactersIn: ",;|\n"))
        var seen = Set([original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])
        var result: [String] = []
        for component in components {
            var text = component.replacingOccurrences(of: #"^\s*\d+[.)]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"«»“”")))
            guard selectionEligible(text), text.allSatisfy({ $0.isLetter || $0.isWhitespace || ["-", "'", "’"].contains($0) }),
                  seen.insert(text.lowercased()).inserted else { continue }
            let word = original.trimmingCharacters(in: .whitespaces)
            if word == word.uppercased() { text = text.uppercased() }
            else if word.first?.isUppercase == true { text = text.prefix(1).uppercased() + text.dropFirst() }
            text = String(original.prefix(while: { $0.isWhitespace })) + text
                + String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
            result.append(text)
            if result.count == 5 { break }
        }
        return result
    }

    static func alternatives(_ raw: [String]) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for value in raw {
            let chunk = CompletionText.nextChunk(value).chunk
            let key = chunk.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            guard !key.isEmpty, key.contains(where: { $0.isLetter }), seen.insert(key).inserted else { continue }
            result.append(chunk)
            if result.count == 5 { break }
        }
        return result
    }

    static func insertionAlternatives(_ raw: [String], before: String, after: String, continuingWord: Bool = false) -> [String] {
        alternatives(raw).map { insertion($0, before: before, after: after, continuingWord: continuingWord) }.filter { !$0.isEmpty }
    }

    static func choiceKey(keyCode: Int64, modifiers: UInt64, count: Int, selected: Int) -> ChoiceDecision {
        guard modifiers & CompletionShortcutMask == 0, count > 0 else { return .pass }
        if keyCode == 53 { return .dismiss }
        if keyCode == 125 { return .select((selected + 1) % count) }
        if keyCode == 126 { return .select((selected + count - 1) % count) }
        if keyCode == 36 || keyCode == 48 { return .accept(min(max(0, selected), count - 1)) }
        let numbers: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4]
        if let index = numbers[keyCode], index < count { return .accept(index) }
        return .pass
    }

    private static let CompletionShortcutMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)

    static func synonymPrompt(before: String, selected: String, after: String) -> String {
        let russian = selected.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        if russian {
            return "Синонимы в контексте. Ответ — только варианты через запятую.\nКонтекст: Это красивый город.\nСлово: красивый\nСинонимы: прекрасный, живописный, замечательный\nКонтекст: Это важная задача.\nСлово: важная\nСинонимы: значимая, существенная, ответственная\nКонтекст: \(before.suffix(500))\(selected)\(after.prefix(500))\nСлово: \(selected)\nСинонимы:"
        }
        return "Synonyms in context. Answer with synonyms separated by commas.\nContext: This is a beautiful city.\nWord: beautiful\nSynonyms: lovely, gorgeous, stunning\nContext: This is an important task.\nWord: important\nSynonyms: significant, essential, crucial\nContext: \(before.suffix(500))\(selected)\(after.prefix(500))\nWord: \(selected)\nSynonyms:"
    }

    static func insertionPrompt(before: String, after: String) -> String {
        let russian = (before + after).unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        if russian {
            return "Заполни пропуск, сохрани текст справа.\nДо: Я очень \nПосле:  видеть тебя.\nВставка: рад\nДо: Это очень \nПосле:  результат.\nВставка: хороший\nДо: \(before.suffix(1000))\nПосле: \(after.prefix(500))\nВставка:"
        }
        return "Fill the gap without repeating the text on the right.\nBefore: I am very \nAfter:  to see you.\nInsert: happy\nBefore: This is a \nAfter:  result.\nInsert: good\nBefore: \(before.suffix(1000))\nAfter: \(after.prefix(500))\nInsert:"
    }
}
