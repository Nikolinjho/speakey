import Foundation

/// Чистая логика автодополнения: чистка ответа модели, разбиение по словам,
/// «съедание» набранного поверх подсказки, свежесть и фильтр секретов.
enum CompletionText {
    /// Служебные токены модели: <eos>, <|im_end|>, незакрытый <|... в конце.
    private static let specialToken = try! NSRegularExpression(
        pattern: #"<\|[^>\n]*(?:\|>|$)|</?(?:eos|bos|pad|unk|s|end_of_text|start_of_turn|end_of_turn)>"#,
        options: [.caseInsensitive])

    /// Обрезать на первом \n, убрать повтор хвоста `before`, ограничить maxWords словами; "" если пусто/мусор.
    static func clean(_ raw: String, before: String, maxWords: Int) -> String {
        guard maxWords > 0 else { return "" }
        var s = raw
        // Всё после первого служебного токена — мусор.
        if let m = specialToken.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r = Range(m.range, in: s) {
            s = String(s[..<r.lowerBound])
        }
        if let nl = s.firstIndex(where: { $0.isNewline }) { s = String(s[..<nl]) }
        // Перед кареткой уже пробел — ведущий пробел ответа лишний.
        if let last = before.last, last.isWhitespace {
            s = String(s.drop(while: { $0.isWhitespace }))
        }
        s = stripRepeat(s, before: before)
        s = trimTrailing(s)
        if s.allSatisfy({ $0.isWhitespace }) { return "" }

        var words = 0
        var inWord = false
        var cut = s.endIndex
        for i in s.indices {
            if s[i].isWhitespace {
                inWord = false
            } else if !inWord {
                words += 1
                if words > maxWords { cut = i; break }
                inWord = true
            }
        }
        return trimTrailing(String(s[..<cut]))
    }

    /// Следующий кусок для Tab: ведущие пробелы + непрерывный не-пробельный ран (пунктуация входит).
    static func nextChunk(_ s: String) -> (chunk: String, rest: String) {
        var i = s.startIndex
        while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        if i == s.endIndex { return (s, "") }
        while i < s.endIndex, !s[i].isWhitespace { i = s.index(after: i) }
        return (String(s[..<i]), String(s[i...]))
    }

    /// Человек напечатал `typed` поверх подсказки: остаток, если `s` начинается с `typed`; иначе nil.
    static func consume(_ s: String, typed: String) -> String? {
        guard s.hasPrefix(typed) else { return nil }
        return String(s.dropFirst(typed.count))
    }

    /// Ответ свеж, если текст до каретки сейчас равен тому, с которым запрашивали.
    static func isFresh(requestedBefore: String, currentBefore: String) -> Bool {
        requestedBefore == currentBefore
    }

    /// Токены ≥20 симв. со смесью букв/цифр, sk-/ghp_/xox, пароли после «пароль:/password:» → «•••».
    static func redactSecrets(_ text: String) -> String {
        var s = text
        for re in secretPatterns {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "•••")
        }
        s = passwordPattern.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2•••")
        // Длинный токен без «говорящего» префикса: нужна смесь букв и цифр.
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in longTokenPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let tok = ns.substring(with: m.range)
            let hasLetter = tok.contains { $0.isLetter }
            let hasDigit = tok.contains { $0.isNumber }
            guard hasLetter && hasDigit else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + "•••"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Слово, которое набирается прямо сейчас (хвост без пробела/знаков); "" если `before` кончается не на слово.
    static func lastWord(_ before: String) -> String {
        var chars: [Character] = []
        for ch in before.reversed() {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "'" || ch == "’" {
                chars.append(ch)
            } else {
                break
            }
        }
        return String(chars.reversed())
    }

    // MARK: - Внутреннее

    private static let secretPatterns: [NSRegularExpression] = [
        #"\bsk-[A-Za-z0-9_\-]{16,}"#,
        #"\bgh[opsur]_[A-Za-z0-9]{16,}"#,
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let passwordPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(пароль|password|passwd|pwd)(\s*[:=]\s*)\S+"#)

    private static let longTokenPattern = try! NSRegularExpression(pattern: #"[A-Za-z0-9_\-+=]{20,}"#)

    private static func trimTrailing(_ s: String) -> String {
        var t = Substring(s)
        while let l = t.last, l.isWhitespace { t = t.dropLast() }
        return String(t)
    }

    /// Модель повторила хвост `before` (например «как» → «как дела»): срезаем повтор.
    /// Повтор — самый длинный суффикс `before` с границы слова, с которого начинается ответ.
    /// «ко» → «корабль» не трогаем: это дописывание слова, а не повтор.
    private static func stripRepeat(_ s: String, before: String) -> String {
        let window = 200
        let tail = Array(before.suffix(window))
        let sc = Array(s)
        guard !tail.isEmpty, !sc.isEmpty else { return s }
        for start in 0..<tail.count {
            let atBoundary = start == 0
                ? before.count <= window
                : !(tail[start - 1].isLetter || tail[start - 1].isNumber)
            guard atBoundary, !tail[start].isWhitespace else { continue }
            let k = tail.count - start
            guard k <= sc.count else { continue }
            guard tail[start...].filter({ !$0.isWhitespace }).count >= 2 else { continue }
            var same = true
            for j in 0..<k where String(tail[start + j]).lowercased() != String(sc[j]).lowercased() {
                same = false
                break
            }
            guard same else { continue }
            // Хвост кончается словом, а в ответе слово продолжается — это дописывание, не повтор.
            if let last = tail.last, last.isLetter || last.isNumber,
               k < sc.count, sc[k].isLetter || sc[k].isNumber { continue }
            return String(sc[k...])
        }
        return s
    }
}

struct CompletionContext {
    var appName: String; var before: String
    var screenText: String? = nil; var clipboard: String? = nil
    var globalInstruction: String? = nil; var appInstruction: String? = nil
    var snippets: [String] = []; var terms: [String] = []
}
