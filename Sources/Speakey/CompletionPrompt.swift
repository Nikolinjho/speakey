import Foundation

/// Сборка документа для base-модели и затравки Whisper.
enum CompletionPrompt {
    private static let maxBefore = 1200

    /// Документ для base-модели: шапка с инструкциями/контекстом, затем `before` ДОСЛОВНО в конце.
    /// Приоритет при нехватке бюджета: before(≤1200) > инструкции > snippets > terms > screen > clipboard.
    /// Итог строго ≤ budget символов.
    static func build(_ c: CompletionContext, budget: Int = 3000) -> String {
        let name = c.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (name.isEmpty ? "Черновик" : "\(name), черновик") + ":\n"
        let tailBefore = trimLeft(c.before, max: min(maxBefore, max(0, budget - label.count)))
        let tail = label + tailBefore
        // Секции заканчиваются «\n»; ещё один «\n» отделяет шапку от хвоста.
        var remaining = budget - tail.count - 1

        var global: String?, app: String?, snippets: String?, terms: String?, screen: String?, clip: String?
        func take(_ title: String, _ body: String?, cap: Int) -> String? {
            guard remaining > 0, let body = body?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { return nil }
            let head = title + "\n"
            let room = min(cap, remaining - head.count - 1)
            guard room >= 10 || (room > 0 && body.count <= room) else { return nil }
            let text = head + trimRight(body, max: room) + "\n"
            remaining -= text.count
            return text
        }
        global = take("Заметки автора:", c.globalInstruction, cap: 600)
        app = take("Правила для \(name.isEmpty ? "приложения" : name):", c.appInstruction, cap: 600)
        if remaining > 0, !c.snippets.isEmpty {
            let head = "Примеры текстов автора:\n"
            var body = ""
            for sn in c.snippets {
                let one = sn.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                guard !one.isEmpty else { continue }
                let line = "- " + trimRight(one, max: 300) + "\n"
                if head.count + body.count + line.count > remaining { break }
                body += line
            }
            if !body.isEmpty { snippets = head + body; remaining -= head.count + body.count }
        }
        if remaining > 0, !c.terms.isEmpty {
            let head = "Частые слова: "
            var list = ""
            for t in c.terms where !t.isEmpty {
                let add = (list.isEmpty ? "" : ", ") + t
                if head.count + list.count + add.count + 1 > remaining { break }
                list += add
            }
            if !list.isEmpty { terms = head + list + "\n"; remaining -= head.count + list.count + 1 }
        }
        screen = take("Текст на экране:", c.screenText, cap: 1500)
        clip = take("Буфер обмена:", c.clipboard, cap: 500)

        let header = [global, app, screen, clip, snippets, terms].compactMap { $0 }.joined()
        var result = header.isEmpty ? tail : header + "\n" + tail
        if result.count > budget { result = String(result.suffix(max(0, budget))) }
        return result
    }

    /// Затравка-словарь для Whisper (фича B): слова через запятую, без повторов, ≤ maxChars.
    static func dictationHint(dictionary: [String], screenTerms: [String], corpusTerms: [String], maxChars: Int = 240) -> String? {
        guard maxChars > 0 else { return nil }
        var seen = Set<String>()
        var out = ""
        for w in dictionary + screenTerms + corpusTerms {
            let word = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
            let add = out.isEmpty ? word : ", " + word
            if out.count + add.count > maxChars { continue }
            out += add
        }
        return out.isEmpty ? nil : out
    }

    /// Термины из текста экрана: токены ≥3 симв.: латиница, слова с цифрами, слова с заглавной не в начале
    /// предложения (начало текста или после .!?); без стоп-слов; по частоте, затем по первому появлению.
    static func terms(from text: String, max: Int) -> [String] {
        guard max > 0 else { return [] }
        var counts: [String: Int] = [:]
        var order: [String: Int] = [:]
        var surface: [String: String] = [:]
        var lastSig: Character? = nil   // последний непробельный символ текста
        var tokPrev: Character? = nil   // он же, но на момент начала текущего токена
        var tok: [Character] = []
        var seq = 0

        func flush() {
            var chars = tok
            tok = []
            while let f = chars.first, f == "-" || f == "_" { chars.removeFirst() }
            while let l = chars.last, l == "-" || l == "_" { chars.removeLast() }
            guard chars.count >= 3 else { return }
            let word = String(chars)
            let key = word.lowercased()
            guard !stopWords.contains(key) else { return }
            let letters = chars.filter { $0.isLetter }
            guard !letters.isEmpty else { return }
            let latin = letters.allSatisfy { ($0.unicodeScalars.first?.value ?? 0) < 0x250 }
            let hasDigit = chars.contains { $0.isNumber }
            let capital = chars[0].isUppercase && !isSentenceStart(tokPrev)
            guard latin || hasDigit || capital else { return }
            counts[key, default: 0] += 1
            if order[key] == nil { order[key] = seq; surface[key] = word; seq += 1 }
        }

        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                if tok.isEmpty { tokPrev = lastSig }
                tok.append(ch)
            } else if !tok.isEmpty {
                flush()
            }
            if !ch.isWhitespace { lastSig = ch }
        }
        if !tok.isEmpty { flush() }

        return counts.keys
            .sorted { a, b in
                counts[a]! != counts[b]! ? counts[a]! > counts[b]! : order[a]! < order[b]!
            }
            .prefix(max)
            .map { surface[$0]! }
    }

    // MARK: - Внутреннее

    /// Начало текста или предыдущий значимый символ — конец предложения.
    private static func isSentenceStart(_ prev: Character?) -> Bool {
        guard let p = prev else { return true }
        return p == "." || p == "!" || p == "?" || p == "…"
    }

    /// Обрезать слева до max символов по границе слова (если в остатке есть пробел).
    private static func trimLeft(_ s: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard s.count > max else { return s }
        var t = Substring(s.suffix(max))
        let cutMidWord = !(s[s.index(s.endIndex, offsetBy: -max - 1)].isWhitespace || t.first!.isWhitespace)
        if cutMidWord, let ws = t.firstIndex(where: { $0.isWhitespace }) {
            t = t[t.index(after: ws)...]
        }
        return String(t)
    }

    /// Обрезать справа до max символов по границе слова.
    private static func trimRight(_ s: String, max: Int) -> String {
        guard max > 0 else { return "" }
        guard s.count > max else { return s }
        var t = Substring(s.prefix(max))
        let cutMidWord = !(s[s.index(s.startIndex, offsetBy: max)].isWhitespace || t.last!.isWhitespace)
        if cutMidWord, let ws = t.lastIndex(where: { $0.isWhitespace }) {
            t = t[..<ws]
        }
        return String(t).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let stopWords: Set<String> = [
        // ru
        "что", "как", "это", "для", "при", "или", "все", "всё", "его", "еще", "ещё", "она", "они", "так",
        "там", "тут", "уже", "был", "была", "были", "было", "быть", "есть", "если", "когда", "только",
        "можно", "нужно", "мой", "моя", "наш", "ваш", "этот", "эта", "эти", "тот", "про", "над", "под",
        "без", "между", "через", "после", "перед", "чтобы", "потому", "очень", "даже", "тоже", "либо",
        "также", "который", "которая", "которое", "которые", "себя", "меня", "тебя", "нас", "вас", "них",
        "ним", "ней", "нее", "неё", "кто", "где", "куда", "почему", "зачем", "ему", "мне", "тебе", "нам",
        "вам", "вот", "вон", "нет", "его", "ему", "али", "ага", "ого", "при", "один", "одна", "два", "три",
        // en
        "the", "and", "for", "are", "but", "not", "you", "all", "can", "her", "was", "one", "our", "out",
        "has", "have", "had", "his", "how", "its", "may", "new", "now", "see", "two", "who", "with",
        "this", "that", "from", "they", "will", "would", "there", "their", "what", "about", "which",
        "when", "your", "been", "were", "said", "each", "she", "than", "them", "these", "some", "into",
        "more", "other", "then", "only", "over", "such", "also", "just", "like", "here", "very", "any",
        "use", "get", "let", "did", "does", "don", "per", "via", "yes", "off", "too", "him", "own",
        "should", "could", "where", "while", "because", "being", "before", "after", "between",
    ]
}
