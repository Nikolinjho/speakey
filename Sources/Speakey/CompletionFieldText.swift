import Foundation

/// Все части снимка используют индексы одного источника Accessibility.
enum CompletionFieldText {
    enum RangeRead {
        case text(String)
        case unsupported
        case outOfBounds
        case unavailable
    }

    static func read(_ range: NSRange, truncatingAtEnd: Bool = false,
                     readRange: (NSRange) -> RangeRead, fullValue: () -> String?) -> String? {
        guard range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        if range.length == 0 { return "" }
        switch readRange(range) {
        case .text(let text):
            return text.utf16.count == range.length ? text : nil
        case .unsupported:
            guard let value = fullValue(), range.location <= (value as NSString).length,
                  range.length <= (value as NSString).length - range.location else { return nil }
            return (value as NSString).substring(with: range)
        case .unavailable:
            return nil
        case .outOfBounds:
            guard truncatingAtEnd,
                  case .text(let empty) = readRange(NSRange(location: range.location, length: 0)),
                  empty.isEmpty else { return nil }
            // У rich text AXNumberOfCharacters может учитывать разделители абзацев,
            // отсутствующие в AXStringForRange. Ищем доступный хвост в тех же индексах.
            var low = 0, high = range.length
            var result = ""
            while high - low > 1 {
                let length = low + (high - low) / 2
                switch readRange(NSRange(location: range.location, length: length)) {
                case .text(let text):
                    guard text.utf16.count == length else { return nil }
                    low = length
                    result = text
                case .outOfBounds:
                    high = length
                case .unsupported, .unavailable:
                    return nil
                }
            }
            return result
        }
    }
}
