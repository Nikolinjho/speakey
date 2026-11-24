import Foundation
import NaturalLanguage

/// Производный индекс живёт только в памяти. Исходный корпус остаётся зашифрованным.
final class PersonalWritingIndex {
    struct Continuation {
        let text: String
        let example: String
        let support: Int
        let recordID: UUID
    }
    struct Profile {
        var snippets: [String] = []
        var terms: [String] = []
        var continuation: Continuation? = nil
    }
    private struct Token {
        let key: String
        let range: Range<String.Index>
        let sentenceBreak: Bool
    }
    private struct Document {
        let record: PersonalCorpus.Record
        let tokens: [Token]
        let words: Set<String>
        let language: String?
    }
    private struct Occurrence { let document: Int; let token: Int }
    private struct Term {
        var count = 0
        var forms: [String: Int] = [:]
        var apps: [String: Int] = [:]
    }
    private let documents: [Document]
    private let byID: [UUID: Int]
    private let postings: [String: [Occurrence]]
    private let wordDocuments: [String: Set<Int>]
    private let vocabulary: [String]
    private let termStatistics: [String: Term]
    private let globalTerms: [String]
    private let appTerms: [String: [String]]
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let stopWords: Set<String> = [
        "для", "это", "как", "что", "при", "или", "так", "его", "она", "они", "the", "and", "for", "with", "this", "that", "from", "are", "was", "you", "your"
    ]

    init(records: [PersonalCorpus.Record], previous: PersonalWritingIndex? = nil) {
        var docs: [Document] = []
        var ids: [UUID: Int] = [:]
        var occurrences: [String: [Occurrence]] = [:]
        var inverted: [String: Set<Int>] = [:]
        var statistics: [String: Term] = [:]
        for record in records {
            let document: Document
            if let old = previous, let position = old.byID[record.id], old.documents[position].record.text.utf8.elementsEqual(record.text.utf8) {
                let cached = old.documents[position]
                document = Document(record: record, tokens: cached.tokens, words: cached.words, language: cached.language)
            } else {
                let tokens = Self.tokenize(record.text)
                document = Document(record: record, tokens: tokens,
                                    words: Set(tokens.map(\.key).filter(Self.significant)), language: Self.language(record.text))
            }
            let index = docs.count
            docs.append(document); ids[record.id] = index
            for word in document.words { inverted[word, default: []].insert(index) }
            for (position, token) in document.tokens.enumerated() {
                occurrences[token.key, default: []].append(Occurrence(document: index, token: position))
                guard token.key.count >= 4, Self.significant(token.key) else { continue }
                var term = statistics[token.key] ?? Term()
                term.count += 1
                term.forms[String(record.text[token.range]), default: 0] += 1
                term.apps[record.bundleID, default: 0] += 1
                statistics[token.key] = term
            }
        }
        documents = docs; byID = ids; postings = occurrences
        wordDocuments = inverted; vocabulary = occurrences.keys.sorted(); termStatistics = statistics
        let eligible = statistics.filter { $0.value.count >= 2 }
        globalTerms = eligible.keys.sorted {
            let a = eligible[$0]!.count, b = eligible[$1]!.count
            return a != b ? a > b : $0 < $1
        }
        var perApp: [String: [String]] = [:]
        for (word, term) in eligible {
            for app in term.apps.keys { perApp[app, default: []].append(word) }
        }
        appTerms = perApp.reduce(into: [:]) { result, item in
            let app = item.key
            result[app] = item.value.sorted {
                let a = eligible[$0]!, b = eligible[$1]!
                let sa = a.count + (a.apps[app] ?? 0) * 2, sb = b.count + (b.apps[app] ?? 0) * 2
                return sa != sb ? sa > sb : $0 < $1
            }
        }
    }

    func examples(before: String, bundleID: String? = nil, limit: Int) -> [String] {
        rankedDocuments(before: before, bundleID: bundleID).prefix(max(0, limit)).map { documents[$0].record.text }
    }

    func terms(bundleID: String? = nil, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let keys: [String]
        if let bundleID {
            let candidates = Set(globalTerms.prefix(limit)).union((appTerms[bundleID] ?? []).prefix(limit))
            keys = candidates.sorted {
                let a = termStatistics[$0]!, b = termStatistics[$1]!
                let sa = a.count + (a.apps[bundleID] ?? 0) * 2, sb = b.count + (b.apps[bundleID] ?? 0) * 2
                return sa != sb ? sa > sb : $0 < $1
            }
        } else { keys = Array(globalTerms.prefix(limit)) }
        return keys.prefix(limit).compactMap { key in
            termStatistics[key]?.forms.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key
        }
    }

    /// Написание → вес. Каждая форма слова идёт со своим счётом; с `bundleID` к нему добавляется
    /// доля двойного числа записей в этом приложении, пропорциональная доле формы (минимум 1).
    /// У слова с одним написанием это `count + 2 × count_в_приложении`.
    func vocabulary(bundleID: String? = nil) -> [String: Int] {
        var result: [String: Int] = [:]
        for term in termStatistics.values where term.count > 0 {
            let appCount = bundleID.flatMap { term.apps[$0] } ?? 0
            for (form, formCount) in term.forms {
                let bonus = appCount > 0 ? Int((Double(2 * appCount * formCount) / Double(term.count)).rounded()) : 0
                result[form, default: 0] += max(1, formCount + bonus)
            }
        }
        return result
    }

    func profile(before: String, bundleID: String, strength: Int) -> Profile {
        guard strength > 0 else { return Profile() }
        let level = min(3, strength)
        let count = [0, 1, 3, 5][level]
        let hint = continuation(after: before, bundleID: bundleID, maxWords: [0, 2, 4, 6][level],
                                minimumSupport: level == 1 ? 3 : 2)
        let focused = hint.flatMap { byID[$0.recordID] }.map { documents[$0].record.bundleID == bundleID } ?? false
        var samples: [String] = hint.map { [$0.example] } ?? []
        for index in rankedDocuments(before: before, bundleID: bundleID) {
            let record = documents[index].record
            // Подтверждённую привычку этого приложения не разбавляем чужими вариантами.
            if focused, record.bundleID != bundleID { continue }
            if record.id != hint?.recordID, !samples.contains(record.text) { samples.append(record.text) }
            if samples.count >= count { break }
        }
        let vocabulary = terms(bundleID: bundleID, limit: level * 10).filter {
            !focused || termStatistics[Self.normalized($0)]?.apps[bundleID] != nil
        }
        return Profile(snippets: Array(samples.prefix(count)), terms: vocabulary, continuation: hint)
    }

    /// Ищем совпадающий хвост, включая недописанное слово. Поддержка считается по разным записям.
    func continuation(after typed: String, bundleID: String? = nil, maxWords: Int = 4,
                      minimumSupport: Int = 2) -> Continuation? {
        guard maxWords > 0, minimumSupport > 0 else { return nil }
        let tail = String(typed.suffix(200))
        let query = Self.tokenize(tail)
        guard query.count >= 2, let last = query.last else { return nil }
        let trailing = tail[last.range.upperBound...]
        guard !trailing.contains(where: Self.sentenceEnd) else { return nil }
        let partial = trailing.isEmpty
        guard !partial || last.key.count >= 2 else { return nil }
        let keys: [String]
        if partial {
            let start = lowerBound(last.key)
            keys = Array(vocabulary[start...].prefix { $0.hasPrefix(last.key) })
        } else { keys = [last.key] }
        let language = Self.language(tail)
        let contexts = documents.map { contextScore($0, bundleID: bundleID, language: language) }
        let lengths = (2...min(8, query.count)).reversed().filter {
            query.suffix($0).map(\.key).joined(separator: " ").count >= 10
        }
        struct Match {
            let document: Int
            let wordStart: Int
            let words: Int
            let continuedWords: Int
            let start: String.Index
            let end: String.Index
        }
        final class Group {
            var records: [UUID: Int] = [:]
            var counts = Array(repeating: 0, count: 9)
            var representatives: [Int: Match] = [:]
        }
        func better(_ a: Match, _ b: Match) -> Bool {
            if contexts[a.document] != contexts[b.document] { return contexts[a.document] > contexts[b.document] }
            let ra = documents[a.document].record, rb = documents[b.document].record
            if ra.date != rb.date { return ra.date > rb.date }
            if ra.id != rb.id { return ra.id.uuidString < rb.id.uuidString }
            return a.wordStart < b.wordStart
        }
        var groups: [String: Group] = [:]
        var consumedPrefixes: [String: Int] = [:]
        for key in keys {
            for occurrence in postings[key] ?? [] {
                let doc = documents[occurrence.document]
                for length in lengths where length <= occurrence.token + 1 {
                    let queryStart = query.count - length
                    let recordStart = occurrence.token - length + 1
                    var agrees = true
                    for offset in 0..<length {
                        let wanted = query[queryStart + offset]
                        let found = doc.tokens[recordStart + offset]
                        if offset < length - 1, wanted.key != found.key { agrees = false; break }
                        if offset > 0, wanted.sentenceBreak != found.sentenceBreak { agrees = false; break }
                    }
                    guard agrees else { continue }
                    let matched = doc.tokens[occurrence.token]
                    let start: String.Index
                    if partial {
                        let word = String(doc.record.text[matched.range])
                        let consumed: Int
                        if let cached = consumedPrefixes[word] { consumed = cached }
                        else {
                            let prefix = word.range(of: String(tail[last.range]), options: [.anchored, .caseInsensitive], locale: Self.locale)
                            consumed = prefix.map { word.distance(from: word.startIndex, to: $0.upperBound) } ?? -1
                            consumedPrefixes[word] = consumed
                        }
                        guard consumed >= 0 else { continue }
                        start = doc.record.text.index(matched.range.lowerBound, offsetBy: consumed)
                    } else { start = matched.range.upperBound }
                    let finishingWord = start < matched.range.upperBound
                    let first = finishingWord ? occurrence.token : occurrence.token + 1
                    var prefixKeys: [String] = []
                    for position in first..<min(doc.tokens.count, first + maxWords) {
                        let token = doc.tokens[position]
                        if position != occurrence.token, token.sentenceBreak { break }
                        let word = position == occurrence.token ? String(token.key.dropFirst(last.key.count)) : token.key
                        guard !word.isEmpty else { continue }
                        prefixKeys.append(word)
                        let groupKey = (finishingWord ? "_" : " ") + prefixKeys.joined(separator: " ")
                        let match = Match(document: occurrence.document, wordStart: recordStart, words: length,
                                          continuedWords: prefixKeys.count, start: start, end: token.range.upperBound)
                        let group = groups[groupKey] ?? Group()
                        let oldLength = group.records[doc.record.id] ?? 0
                        if length > oldLength {
                            group.counts[oldLength] -= oldLength > 0 ? 1 : 0
                            group.counts[length] += 1
                            group.records[doc.record.id] = length
                        }
                        if let old = group.representatives[length] {
                            if better(match, old) { group.representatives[length] = match }
                        } else { group.representatives[length] = match }
                        groups[groupKey] = group
                    }
                    break
                }
            }
        }
        // Длина контекста должна сама иметь достаточно подтверждений, а не брать их у более короткого хвоста.
        var candidates: [(match: Match, words: Int, support: Int)] = []
        for group in groups.values {
            var support = 0
            for length in stride(from: 8, through: 2, by: -1) {
                support += group.counts[length]
                guard support >= minimumSupport else { continue }
                if let match = group.representatives.filter({ $0.key >= length }).map(\.value).sorted(by: better).first {
                    candidates.append((match, length, support))
                }
                break
            }
        }
        guard let best = candidates.sorted(by: { a, b in
            let x = a.match, y = b.match
            if a.words != b.words { return a.words > b.words }
            if contexts[x.document] != contexts[y.document] { return contexts[x.document] > contexts[y.document] }
            if x.continuedWords != y.continuedWords { return x.continuedWords > y.continuedWords }
            if a.support != b.support { return a.support > b.support }
            return better(x, y)
        }).first else { return nil }
        let match = best.match, doc = documents[best.match.document]
        let confirmedStart = match.wordStart + match.words - best.words
        return Continuation(text: String(doc.record.text[match.start..<match.end]),
                            example: String(doc.record.text[doc.tokens[confirmedStart].range.lowerBound..<match.end]),
                            support: best.support, recordID: doc.record.id)
    }

    private func rankedDocuments(before: String, bundleID: String?) -> [Int] {
        let query = Set(Self.tokenize(String(before.suffix(200))).map(\.key).filter(Self.significant))
        guard !query.isEmpty else { return [] }
        let language = Self.language(before)
        var scores: [Int: Double] = [:]
        for word in query {
            let matches = wordDocuments[word] ?? []
            let weight = log(1 + Double(documents.count) / Double(max(1, matches.count)))
            for document in matches { scores[document, default: 0] += weight }
        }
        for index in Array(scores.keys) {
            let doc = documents[index]
            scores[index]! /= sqrt(Double(max(1, doc.words.count)))
            if let bundleID, doc.record.bundleID == bundleID { scores[index]! *= 1.5 }
            if let language, let stored = doc.language { scores[index]! *= language == stored ? 1.2 : 0.5 }
        }
        return scores.keys.sorted {
            if scores[$0] != scores[$1] { return scores[$0]! > scores[$1]! }
            let a = documents[$0].record, b = documents[$1].record
            return a.date != b.date ? a.date > b.date : a.id.uuidString < b.id.uuidString
        }
    }

    private func contextScore(_ doc: Document, bundleID: String?, language: String?) -> Int {
        (bundleID != nil && doc.record.bundleID == bundleID ? 2 : 0)
            + (language != nil && doc.language == language ? 1 : 0)
    }
    private func lowerBound(_ key: String) -> Int {
        var lo = 0, hi = vocabulary.count
        while lo < hi {
            let middle = (lo + hi) / 2
            if vocabulary[middle] < key { lo = middle + 1 } else { hi = middle }
        }
        return lo
    }
    private static func significant(_ key: String) -> Bool { key.count >= 3 && !stopWords.contains(key) }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive], locale: locale).precomposedStringWithCanonicalMapping
    }
    private static func sentenceEnd(_ c: Character) -> Bool { c == "." || c == "!" || c == "?" || c.isNewline }
    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = [], start: String.Index?, boundary = false
        var position = text.startIndex
        while position < text.endIndex {
            let c = text[position]
            if c.isLetter || c.isNumber || c == "_" || c == "-" {
                if start == nil { start = position }
            } else {
                if let first = start {
                    result.append(Token(key: normalized(String(text[first..<position])), range: first..<position, sentenceBreak: boundary))
                    start = nil; boundary = false
                }
                if sentenceEnd(c) { boundary = true }
            }
            position = text.index(after: position)
        }
        if let first = start { result.append(Token(key: normalized(String(text[first...])), range: first..<text.endIndex, sentenceBreak: boundary)) }
        return result
    }
    private static func language(_ text: String) -> String? {
        guard text.filter(\.isLetter).count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.suffix(1500)))
        guard let language = recognizer.dominantLanguage,
              (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.6 else { return nil }
        return language.rawValue
    }
}
