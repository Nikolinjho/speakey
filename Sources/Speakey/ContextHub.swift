import AppKit
import ApplicationServices

struct FieldSnapshot {
    let bundleID: String
    let appName: String
    let before: String
    let caretRect: NSRect   // Cocoa-координаты
    let pid: pid_t
}

/// Снимок поля ввода и сборка контекста для модели. Только вне main-колбэка тапа:
/// AX-запросы синхронные (с таймаутами).
enum ContextHub {
    static func snapshot(maxBefore: Int = 1500) -> FieldSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else { return nil }
        guard let before = AXScreenCheck.textBeforeCaret(maxLen: maxBefore) else { return nil }
        guard let rect = CaretLocator.caretScreenRect(preferCharBefore: true) else { return nil }
        return FieldSnapshot(bundleID: bid, appName: app.localizedName ?? bid, before: before,
                             caretRect: rect, pid: app.processIdentifier)
    }

    static func context(for s: FieldSnapshot) -> CompletionContext {
        var c = CompletionContext(appName: s.appName, before: s.before)
        let g = AutocompletePrefs.globalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty { c.globalInstruction = g }
        let a = AutocompleteAppStore.shared.instruction(s.bundleID).trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { c.appInstruction = a }

        let strength = AutocompletePrefs.personalStrength
        if strength > 0, AutocompletePrefs.recordMode != .off || PersonalCorpus.shared.count > 0 {
            let (nSnippets, nTerms): (Int, Int) = {
                switch strength {
                case 1: return (1, 10)
                case 2: return (3, 20)
                default: return (5, 30)
                }
            }()
            c.snippets = PersonalCorpus.shared.similar(to: s.before, limit: nSnippets)
            c.terms = PersonalCorpus.shared.topTerms(limit: nTerms)
        }

        if AutocompletePrefs.useScreen,
           !AutocompleteAppStore.hardExcluded.contains(s.bundleID),
           let t = ScreenContextProvider.shared.latestText, !t.isEmpty {
            c.screenText = t
        }

        if AutocompletePrefs.useClipboard,
           let clip = NSPasteboard.general.string(forType: .string) {
            let t = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && t.count <= 500 { c.clipboard = t }
        }
        return c
    }
}
