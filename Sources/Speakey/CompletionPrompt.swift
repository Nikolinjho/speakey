import Foundation

/// Сборка документа для base-модели и затравки Whisper.
enum CompletionPrompt {
    private static let maxBefore = 1200
    /// Автоматическое продолжение стабильно при том же контексте. У вариантов свои параметры.
    static let continuationTemperature = 0.0

    /// Документ для base-модели: шапка с инструкциями/контекстом, затем `before` ДОСЛОВНО в конце.
    /// Приоритет при нехватке бюджета: before(≤1200) > инструкции > snippets > terms > screen > clipboard.
    /// Итог строго ≤ budget символов.
    static func build(_ c: CompletionContext, budget: Int = 3000) -> String {
        guard budget > 0 else { return "" }
        let name = c.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        // Маленький бюджет отдаём тексту и инструкции, а не разметке.
        let structured = hasBackground(c) && budget >= 512
        let intro = structured
            ? "Continue the unfinished document using the background context. Output only the continuation, without copying instructions or context labels.\n\n### Background\n"
            : ""
        let label = structured ? "### Document in \(name.isEmpty ? "App" : name)\n"
            : (name.isEmpty ? "Черновик" : "\(name), черновик") + ":\n"
        let tailBefore = trimLeft(c.before, max: min(maxBefore, max(0, budget - label.count)))
        let tail = label + tailBefore
        var remaining = budget - tail.count - intro.count
        let gap = structured ? "\n\n" : "\n"
        func heading(_ english: String, _ russian: String) -> String { structured ? "#### " + english : russian }
        func take(_ title: String, _ body: String?, cap: Int) -> String? {
            guard remaining > 0, let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
            let head = title + "\n"
            let room = min(cap, remaining - head.count - gap.count)
            guard room >= 10 || (room > 0 && body.count <= room) else { return nil }
            let text = head + trimRight(body, max: room) + gap
            remaining -= text.count
            return text
        }
        let global = take(heading("Author instructions", "Заметки автора:"), c.globalInstruction, cap: 600)
        let app = take(heading("Application instructions", "Правила для \(name.isEmpty ? "приложения" : name):"), c.appInstruction, cap: 600)
        var snippets: String?, terms: String?
        if remaining > 0, !c.snippets.isEmpty {
            let head = heading("Author text examples", "Примеры текстов автора:") + "\n"
            var body = ""
            for snippet in c.snippets {
                let one = snippet.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
                guard !one.isEmpty else { continue }
                let line = (structured ? "" : "- ") + trimRight(one, max: 300) + "\n"
                if head.count + body.count + line.count + gap.count > remaining { break }
                body += line
            }
            if !body.isEmpty {
                snippets = head + body.trimmingCharacters(in: .newlines) + gap
                remaining -= snippets!.count
            }
        }
        if remaining > 0, !c.terms.isEmpty {
            let head = structured ? "#### Author vocabulary\n" : "Частые слова: "
            var list = ""
            for term in c.terms where !term.isEmpty {
                let add = (list.isEmpty ? "" : ", ") + term
                if head.count + list.count + add.count + gap.count > remaining { break }
                list += add
            }
            if !list.isEmpty { terms = head + list + gap; remaining -= terms!.count }
        }
        let screen = take(heading("Screen text", "Текст на экране:"), c.screenText, cap: 1500)
        let clip = take(heading("Clipboard", "Буфер обмена:"), c.clipboard, cap: 500)
        let header = [global, app, screen, clip, snippets, terms].compactMap { $0 }.joined()
        let result = header.isEmpty ? tail : intro + header + tail
        return result.count > budget ? String(result.suffix(budget)) : result
    }

    /// Метки фона разрешены только в запросе. Продолжение с контекстом заканчивается
    /// на первом предложении, чтобы модель не приписывала пояснения после ответа.
    static func cleanContinuation(_ raw: String, before: String, context: CompletionContext, maxWords: Int) -> String {
        guard hasBackground(context) else { return CompletionText.clean(raw, before: before, maxWords: maxWords) }
        var stops = ["### Background", "### Document in", "Continue the unfinished document using the background context.",
                     "Output only the continuation, without copying instructions or context labels."]
        func include(_ body: String?, _ names: [String]) {
            if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { stops += names }
        }
        include(context.globalInstruction, ["#### Author instructions", "Author instructions:", "Заметки автора:"])
        include(context.appInstruction, ["#### Application instructions", "Application instructions:", "Правила для \(context.appName):"])
        include(context.screenText, ["#### Screen text", "Screen text:", "Текст на экране:"])
        include(context.clipboard, ["#### Clipboard", "Clipboard:", "Буфер обмена:"])
        if !context.snippets.isEmpty { stops += ["#### Author text examples", "Author text examples:", "Примеры текстов автора:"] }
        if !context.terms.isEmpty { stops += ["#### Author vocabulary", "Author vocabulary:", "Частые слова:"] }
        return CompletionText.clean(raw, before: before, maxWords: maxWords, stopPhrases: stops, singleSentence: true)
    }

    private static func hasBackground(_ c: CompletionContext) -> Bool {
        [c.globalInstruction, c.appInstruction, c.screenText, c.clipboard].contains {
            !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } || c.snippets.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || c.terms.contains { !$0.isEmpty }
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
