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
}
