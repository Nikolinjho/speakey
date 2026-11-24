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
    var target: CompletionTarget? = nil
    var fieldBounds: NSRect? = nil
}

/// Снимок поля ввода и сборка контекста для модели. Только вне main-колбэка тапа:
/// AX-запросы синхронные (с таймаутами).
enum ContextHub {
    static func snapshot(maxBefore: Int = 1500) -> FieldSnapshot? {
        if let target = CompletionTarget.capture() {
            var snapshot = FieldSnapshot(bundleID: target.bundleID, appName: target.appName, before: target.before,
                                         caretRect: target.caret, pid: target.pid)
            snapshot.target = target
            snapshot.fieldBounds = CaretLocator.fieldScreenRect(element: target.element)
            snapshot.textAfterOnLine = CompletionEditing.hasTextOnCurrentLine(after: target.after)
            return snapshot
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bid = app.bundleIdentifier else { return nil }
        guard let before = AXScreenCheck.textBeforeCaret(maxLen: maxBefore) else { return nil }
        guard let element = AXFocusedElement.read(pid: app.processIdentifier, timeout: 0.25),
              canPreviewAtFallbackCaret(in: element),
              let rect = CaretLocator.caretScreenRect(preferCharBefore: true, element: element) else { return nil }
        var snap = FieldSnapshot(bundleID: bid, appName: app.localizedName ?? bid, before: before,
                                 caretRect: rect, pid: app.processIdentifier)
        snap.fieldBounds = CaretLocator.fieldScreenRect(element: element)
        return snap
    }

    /// Без полного снимка показ на строке возможен только у подтверждённой границы.
    private static func canPreviewAtFallbackCaret(in element: AXUIElement) -> Bool {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rawRange = rangeRef, CFGetTypeID(rawRange) == AXValueGetTypeID() else { return false }
        var selection = CFRange()
        guard AXValueGetValue(rawRange as! AXValue, .cfRange, &selection),
              selection.length == 0, selection.location >= 0, selection.location < Int.max else { return false }
        let next = CompletionFieldText.readAXRange(NSRange(location: selection.location, length: 1), from: element)
        return CompletionFieldText.allowsFallbackPreview(after: next) {
            var countRef: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success
                && (countRef as? NSNumber)?.intValue == selection.location
        }
    }

    static func context(for s: FieldSnapshot, corpus: PersonalCorpus = .shared,
                        pasteboard: NSPasteboard = .general) -> CompletionContext {
        var c = CompletionContext(appName: s.appName, before: s.before)
        let g = AutocompletePrefs.globalInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty { c.globalInstruction = g }
        let a = AutocompleteAppStore.shared.instruction(s.bundleID).trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { c.appInstruction = a }

        let strength = AutocompletePrefs.personalStrength
        if strength > 0 {
            let profile = corpus.personalization(before: s.before, bundleID: s.bundleID, strength: strength)
            c.snippets = profile.snippets
            c.terms = profile.terms
        }

        if AutocompletePrefs.useScreen,
           !AutocompleteAppStore.hardExcluded.contains(s.bundleID),
           let t = ScreenContextProvider.shared.text(for: s.pid), !t.isEmpty {
            c.screenText = t
        }

        // Буфер с пометкой «скрытое/временное» (менеджеры паролей) в промпт не идёт.
        let pb = pasteboard
        let concealed = pb.types?.contains { $0.rawValue == "org.nspasteboard.ConcealedType" || $0.rawValue == "org.nspasteboard.TransientType" } ?? false
        if AutocompletePrefs.useClipboard, !concealed,
           let clip = pb.string(forType: .string) {
            let t = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && t.count <= 500 { c.clipboard = t }
        }
        return c
    }
}
