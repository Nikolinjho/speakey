import AppKit

/// Использует общий режим записи: event tap пропускает клавиши в окно настройки.
final class AutocompleteShortcutRecorder {
    static let shared = AutocompleteShortcutRecorder()
    private var monitor: Any?
    private var candidate: CompletionShortcut?
    private var action: CompletionAction?
    private var changed: (() -> Void)?

    static func label(_ shortcut: CompletionShortcut?) -> String {
        guard let shortcut else { return L10n.autocomplete("unassigned") }
        return HotkeyRecorderPanel.parts(mods: CGEventFlags(rawValue: shortcut.modifiers),
                                        keyLabel: KeyLabels.symbol(forKeyCode: Int(shortcut.keyCode))).joined()
    }

    func start(_ action: CompletionAction, window: NSWindow?, changed: @escaping () -> Void) {
        HotkeyRecording.begin(stop: { [weak self] in self?.stop() }, in: window)
        self.action = action
        self.changed = changed
        candidate = nil
        AutocompleteController.shared.contextReset()
        HotkeyRecorderPanel.shared.show(what: L10n.autocomplete("action.\(action.rawValue)"), over: window,
                                       onCommit: { [weak self] in self?.commit() },
                                       onCancel: { [weak self] in self?.stop() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let action = self.action else { return event }
            HotkeyRecording.noteActivity()
            guard event.type == .keyDown else { return nil }
            let mods = UInt64(event.modifierFlags.rawValue) & CompletionShortcut.modifierMask
            if event.keyCode == 53, mods == 0 { self.stop(); return nil }
            let shortcut = CompletionShortcut(keyCode: Int64(event.keyCode), modifiers: mods)
            let flags = CGEventFlags(rawValue: mods)
            let parts = HotkeyRecorderPanel.parts(mods: flags, keyLabel: KeyLabels.symbol(forKeyCode: Int(event.keyCode)))
            self.candidate = nil
            var rejection: String?
            var warning: String?
            if !shortcut.isValid(for: action) { rejection = L10n.autocomplete("invalidShortcut") }
            else if let conflict = CompletionShortcut.conflict(shortcut, for: action, bindings: AutocompletePrefs.shortcuts) {
                rejection = String(format: L10n.autocomplete("shortcutBusy"), L10n.autocomplete("action.\(conflict.rawValue)"))
            } else if let busy = HotkeyGuard.ourBusy(mode: "key", keyCode: Int(event.keyCode), mods: mods, excluding: action.hotkeySlot) {
                rejection = HotkeyGuard.busyMessage(busy)
            } else {
                switch HotkeyGuard.verdict(keyCode: Int(event.keyCode), mods: flags) {
                case .blocked(let busy): rejection = HotkeyGuard.busyMessage(busy)
                case .warn(let busy): warning = HotkeyGuard.conflictMessage(busy)
                case .ok: break
                }
            }
            if let rejection { HotkeyRecorderPanel.shared.warn(rejection, parts: parts) }
            else {
                self.candidate = shortcut
                HotkeyRecorderPanel.shared.render(parts: parts, complete: true, warning: warning)
            }
            return nil
        }
    }

    private func commit() {
        guard let action, let candidate else { return }
        AutocompletePrefs.setShortcut(candidate, for: action)
        let update = changed
        stop()
        update?()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; candidate = nil; action = nil; changed = nil
        HotkeyRecording.end()
        HotkeyRecorderPanel.shared.hide()
    }
}

extension CompletionAction {
    var hotkeySlot: HotkeyGuard.Slot {
        switch self {
        case .nextWord: return .completionWord
        case .acceptAll: return .completionAll
        case .manual: return .completionManual
        case .toggleApp: return .completionApp
        case .toggleGlobal: return .completionGlobal
        case .alternatives: return .completionAlternatives
        case .synonyms: return .completionSynonyms
        }
    }
}
