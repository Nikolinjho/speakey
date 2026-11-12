import AppKit
import ApplicationServices

struct FieldSnapshot {
    let bundleID: String
    let appName: String
    let before: String
    let caretRect: NSRect   // Cocoa-координаты
    let pid: pid_t
    /// Справа от каретки на той же строке есть текст — подсказка легла бы поверх него.
    var textAfterOnLine = false
}

/// Снимок поля ввода и сборка контекста для модели. Только вне main-колбэка тапа:
/// AX-запросы синхронные (с таймаутами).
enum ContextHub {
    static func snapshot(maxBefore: Int = 1500) -> FieldSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else { return nil }
        guard let before = AXScreenCheck.textBeforeCaret(maxLen: maxBefore) else { return nil }
        guard let rect = CaretLocator.caretScreenRect(preferCharBefore: true) else { return nil }
        var snap = FieldSnapshot(bundleID: bid, appName: app.localizedName ?? bid, before: before,
                                 caretRect: rect, pid: app.processIdentifier)
        snap.textAfterOnLine = charAfterCaret().map { $0 != "\n" && $0 != "\r" } ?? false
        return snap
    }

    /// Символ сразу после каретки: nil — каретка в конце текста или поле не ответило.
    private static func charAfterCaret() -> Character? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let el = unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(el, 0.05)
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(unsafeDowncast(rr as AnyObject, to: AXValue.self), .cfRange, &sel) else { return nil }
        var want = CFRange(location: sel.location + sel.length, length: 1)
        guard let v = AXValueCreate(.cfRange, &want) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                         v, &out) == .success,
              let str = out as? String else { return nil }
        return str.first
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
           let t = ScreenContextProvider.shared.text(for: s.pid), !t.isEmpty {
            c.screenText = t
        }

        // Буфер с пометкой «скрытое/временное» (менеджеры паролей) в промпт не идёт.
        let pb = NSPasteboard.general
        let concealed = pb.types?.contains { $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType" } ?? false
        if AutocompletePrefs.useClipboard, !concealed,
           let clip = pb.string(forType: .string) {
            let t = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && t.count <= 500 { c.clipboard = t }
        }
        return c
    }
}
