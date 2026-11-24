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

    /// Источники слов для исправления расшифровки: экран, недавние диктовки, корпус, словарь.
    /// Выключено `AutocompletePrefs.dictationContext` — пусто. Пустые источники пропускаем.
    /// Зовётся с главного потока.
    static func sources(pid: pid_t, bundleID: String) -> [ContextSource] {
        guard AutocompletePrefs.dictationContext else { return [] }
        var result: [ContextSource] = []
        func add(_ kind: ContextSource.Kind, _ words: [String: Int]) {
            if !words.isEmpty { result.append(ContextSource(kind: kind, words: words)) }
        }

        // Экран — только если разрешён и приложение включено (как в prepare()).
        if AutocompletePrefs.useScreen, AutocompleteAppStore.shared.isEnabled(bundleID),
           let screen = ScreenContextProvider.shared.text(for: pid) {
            add(.screen, frequencies(of: [screen]))
        }

        // Диктовки в истории не хранят приложение, поэтому берём все за последние 2 часа, не больше 20.
        let since = Date().addingTimeInterval(-2 * 3600)
        let recent = VoiceHistory.shared.all()
            .filter { $0.resolvedKind == .dictation && $0.date >= since }
            .suffix(20)
        add(.recentDictation, frequencies(of: recent.map { $0.text }))

        add(.corpus, PersonalCorpus.shared.vocabulary(bundleID: bundleID))
        add(.dictionary, frequencies(of: VoiceDictionary.shared.pairs().map { $0.1 }))
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
