import AppKit

/// Затравка распознавания с контекстом (фича B автодополнения). При выключенном
/// `AutocompletePrefs.dictationContext` отдаёт ровно то, что было раньше, — словарь диктовки.
enum DictationContext {
    /// Зовётся в начале диктовки: просит снимок текста экрана у активного приложения. Асинхронно,
    /// ничего не ждём; без разрешения провайдер тихо оставит nil.
    static func prepare() {
        guard AutocompletePrefs.dictationContext, AutocompletePrefs.useScreen,
              let app = NSWorkspace.shared.frontmostApplication,
              AutocompleteAppStore.shared.isEnabled(app.bundleIdentifier ?? "") else { return }
        ScreenContextProvider.shared.refreshIfNeeded(pid: app.processIdentifier)
    }

    /// Слова для затравки whisper. Выключено — байт-в-байт `VoiceDictionary.recognitionHint()`.
    /// Включено — словарь + термины экрана + частые слова корпуса, ≤ 240 символов (вместе с фразами
    /// затравки это ≤ 495 при лимите 600 в WhisperBridge).
    static func hint() -> String? {
        guard AutocompletePrefs.dictationContext else { return VoiceDictionary.shared.recognitionHint() }
        // Текст экрана — только того окна, куда пойдёт диктовка, и свежий.
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let screen = ScreenContextProvider.shared.text(for: pid) ?? ""
        let dictionary = (VoiceDictionary.shared.recognitionHint() ?? "")
            .components(separatedBy: ", ").filter { !$0.isEmpty }
        return CompletionPrompt.dictationHint(
            dictionary: dictionary,
            screenTerms: CompletionPrompt.terms(from: screen, max: 12),
            corpusTerms: PersonalCorpus.shared.topTerms(limit: 12),
            maxChars: 240)
    }

    /// Общий кэш звуковых ключей: переживает пересборку корпуса и смену экрана.
    static let keyCache = ContextKeyCache()

    /// Что нужно для подбора слов. Снимается на main из того, что живёт только там и стоит дёшево
    /// (история диктовок, словарь, настройки); экран и корпус берутся позже, в фоне.
    struct SourceRequest {
        let pid: pid_t
        let bundleID: String
        let screenAllowed: Bool
        let recent: [String: Int]
        let dictionary: [String: Int]
    }

    /// Зовётся с главного потока: только main-only и дешёвое. Выключено
    /// `AutocompletePrefs.dictationContext` — nil, ничего не собираем.
    static func sourceRequest(pid: pid_t, bundleID: String) -> SourceRequest? {
        guard AutocompletePrefs.dictationContext else { return nil }
        // Диктовки в истории не хранят приложение, поэтому берём все за последние 2 часа, не больше 20.
        let since = Date().addingTimeInterval(-2 * 3600)
        let recent = VoiceHistory.shared.all()
            .filter { $0.resolvedKind == .dictation && $0.date >= since }
            .suffix(20)
        return SourceRequest(
            pid: pid, bundleID: bundleID,
            // Экран — только если разрешён и приложение включено (как в prepare()).
            screenAllowed: AutocompletePrefs.useScreen && AutocompleteAppStore.shared.isEnabled(bundleID),
            recent: frequencies(of: recent.map { $0.text }),
            dictionary: frequencies(of: VoiceDictionary.shared.pairs().map { $0.1 }))
    }

    /// Источники слов для исправления расшифровки: экран, недавние диктовки, корпус, словарь.
    /// ⚠️ НЕ С ГЛАВНОГО ПОТОКА. Корпус при первом обращении расшифровывается и строит индекс целиком
    /// (секунды на большом корпусе), а main держит runloop нашего event-tap. Зовётся на
    /// `transcribeQueue`, после первого прохода и только если он что-то распознал. Пустые пропускаем.
    static func sources(_ request: SourceRequest) -> [ContextSourceIndex] {
        var result: [ContextSourceIndex] = []
        func add(_ kind: ContextSource.Kind, _ words: [String: Int]) {
            if !words.isEmpty { result.append(ContextSourceIndex(ContextSource(kind: kind, words: words), keys: keyCache)) }
        }
        if request.screenAllowed, let screen = ScreenContextProvider.shared.text(for: request.pid) {
            add(.screen, frequencies(of: [screen]))
        }
        add(.recentDictation, request.recent)
        let corpus = PersonalCorpus.shared.contextSource(bundleID: request.bundleID, keys: keyCache)
        if !corpus.isEmpty { result.append(corpus) }
        add(.dictionary, request.dictionary)
        return result
    }

    /// Сколько раз каждое написание встретилось в текстах.
    private static func frequencies(of texts: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for text in texts {
            for word in ContextLexicon.words(in: text) { counts[word, default: 0] += 1 }
        }
        return counts
    }
}
