import AppKit
import ApplicationServices

private final class CompletionOwnTextView {
    weak var view: NSTextView?
    init(_ view: NSTextView) { self.view = view }
}

struct CompletionFieldIdentity: Equatable {
    let pid: pid_t
    let element: AXUIElement
    private var ownView: CompletionOwnTextView? = nil

    init(pid: pid_t, element: AXUIElement, ownTextView: NSTextView? = nil) {
        self.pid = pid; self.element = element
        if let ownTextView { ownView = CompletionOwnTextView(ownTextView) }
    }

    /// Читается исходное поле, даже если фокус уже перешёл в другое приложение.
    /// Слишком большой документ пропускается целиком, фрагменты в корпус не попадают.
    func readText(limit: Int = 32_000) -> String? {
        guard limit > 0, !TextReplacer.secureInputActive else { return nil }
        if pid == getpid() {
            if !Thread.isMainThread { return DispatchQueue.main.sync { self.readText(limit: limit) } }
            // Полевой редактор NSTextField переиспользуется другими контролами.
            // Его нельзя считать постоянной идентичностью исходного поля.
            guard let view = ownView?.view, !view.isFieldEditor, view.window != nil, view.isEditable,
                  view.string.utf16.count <= limit else { return nil }
            return view.string
        }
        guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.05)
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        var currentPID: pid_t = 0
        guard AXUIElementGetPid(element, &currentPID) == .success, currentPID == pid,
              let role = attribute(kAXRoleAttribute) as? String,
              [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role),
              attribute(kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole as String,
              let count = attribute(kAXNumberOfCharactersAttribute) as? NSNumber,
              count.intValue >= 0, count.intValue <= limit else { return nil }
        if count.intValue == 0 { return "" }
        var range = CFRange(location: 0, length: count.intValue)
        guard let argument = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         argument, &value) == .success,
              let text = value as? String, text.utf16.count == count.intValue else { return nil }
        return text
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
    }
}

/// Снимок одного поля. Чтение и проверка выполняются только вне колбэка event tap.
struct CompletionTarget {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let range: CFRange
    let before: String
    let selected: String
    let after: String
    let caret: NSRect
    var textFont: NSFont? = nil

    private var ownTextView: CompletionOwnTextView? = nil
    var fieldIdentity: CompletionFieldIdentity {
        CompletionFieldIdentity(pid: pid, element: element, ownTextView: ownTextView?.view)
    }

    static func capture() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier,
              !AutocompleteAppStore.hardExcluded.contains(bid) else { return nil }
        // Собственный AX-элемент обслуживается напрямую AppKit, без межпроцессного main-hop.
        if app.processIdentifier == getpid(), !Thread.isMainThread {
            return DispatchQueue.main.sync { Self.capture() }
        }
        guard SecureInputPolicy.focusedFieldVerdict() == .ordinary else { return nil }
        guard let element = AXFocusedElement.read(pid: app.processIdentifier) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier,
              let rawRange = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rawRange) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(rawRange as AnyObject, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0, range.length <= 120,
              range.location <= Int.max - range.length else { return nil }
        var cachedValue: String?
        var readValue = false
        func fullValue() -> String? {
            if !readValue { cachedValue = attribute(element, kAXValueAttribute) as? String; readValue = true }
            return cachedValue
        }
        let total = (attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? fullValue().map { ($0 as NSString).length }
        guard let total, range.location + range.length <= total else { return nil }
        let start = max(0, range.location - 1500)
        let end = range.location + range.length
        func text(_ span: CFRange, truncatingAtEnd: Bool = false) -> String? {
            CompletionFieldText.read(NSRange(location: span.location, length: span.length),
                                     truncatingAtEnd: truncatingAtEnd,
                                     readRange: { CompletionFieldText.readAXRange($0, from: element) },
                                     fullValue: fullValue)
        }
        guard let before = text(CFRange(location: start, length: range.location - start)),
              let selected = text(range),
              let after = text(CFRange(location: end, length: min(1000, total - end)), truncatingAtEnd: true),
              let caret = CaretLocator.caretScreenRect(preferCharBefore: range.length == 0, element: element) else { return nil }
        var target = Self(element: element, pid: pid, bundleID: bid, appName: app.localizedName ?? bid, range: range,
                          before: before, selected: selected, after: after, caret: caret)
        target.textFont = CaretLocator.fontNearCaret(element: element, range: range)
        if pid == getpid(), let view = NSApp?.keyWindow?.firstResponder as? NSTextView, view.isEditable {
            target.ownTextView = CompletionOwnTextView(view)
        }
        return target
    }

    /// Ожидаемый снимок после набора части подсказки. Это не подтверждение записи:
    /// перед вставкой он всё равно сравнивается с настоящим полем.
    func expectingInsertion(_ text: String) -> Self {
        let prefix = (before + text) as NSString
        return Self(element: element, pid: pid, bundleID: bundleID, appName: appName,
                    range: CFRange(location: range.location + text.utf16.count, length: 0),
                    before: prefix.substring(from: max(0, prefix.length - 1500)), selected: "", after: after,
                    caret: caret, textFont: textFont, ownTextView: ownTextView)
    }

    func matches(_ other: Self) -> Bool {
        pid == other.pid && CFEqual(element, other.element) && range.location == other.range.location
            && range.length == other.range.length && before == other.before && selected == other.selected && after == other.after
    }

    /// Вставляет через AX только при доказанном совпадении поля и текста. Без повторной печати при отказе.
    func commit(_ text: String) -> Bool {
        if pid == getpid(), !Thread.isMainThread { return DispatchQueue.main.sync { self.commit(text) } }
        guard !text.isEmpty, let current = Self.capture(), matches(current),
              !TextReplacer.secureInputActive,
              !SelectionText.isGeckoBundleID(bundleID),
              AutocompleteAppStore.shared.isEnabled(bundleID) else {
            kbLog("completion insertion: цель устарела или вставка запрещена")
            return false
        }
        // WebKit и Electron читают AX-диапазоны, но не обеспечивают запись AXSelectedText.
        // Выбираем транспорт до записи: после неоднозначного AX-ответа повторной печати нет.
        let electronFramework = NSRunningApplication(processIdentifier: pid)?.bundleURL?
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let isElectron = electronFramework.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if CompletionEditing.usesUnicodeInsertion(bundleID: bundleID,
                                                 isElectron: isElectron) {
            kbLog("completion insertion: проверяемая печать Unicode")
            return commitWithUnicode(text)
        }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard result == .success else {
            kbLog("completion insertion: AX отказал, код \(result.rawValue)")
            return false
        }
        guard let updated = Self.capture() else {
            kbLog("completion insertion: после AX поле недоступно")
            return false
        }
        let verified = verifies(text, updated: updated)
        kbLog("completion insertion: AX результат подтверждён=\(verified)")
        return verified
    }

    func verifies(_ text: String, updated: Self, deletingBefore: Int = 0) -> Bool {
        guard pid == updated.pid, CFEqual(element, updated.element), updated.after == after else { return false }
        guard deletingBefore >= 0, before.count >= deletingBefore else { return false }
        let removed = String(before.suffix(deletingBefore)).utf16.count
        let prefix = (String(before.dropLast(deletingBefore)) + text) as NSString
        let expectedBefore = prefix.substring(from: max(0, prefix.length - 1500))
        let collapsed = updated.range.location == range.location - removed + text.utf16.count && updated.range.length == 0
            && updated.before == expectedBefore
        let retained = deletingBefore == 0 && updated.range.location == range.location && updated.selected == text && updated.before == before
        return collapsed || retained
    }

    private func commitWithUnicode(_ text: String) -> Bool {
        guard let current = Self.capture(), matches(current), !TextReplacer.secureInputActive else { return false }
        let source = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var offset = 0
        while offset < units.count {
            var end = min(units.count, offset + 20)
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            Array(units[offset..<end]).withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            for event in [down, up] {
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: kbSyntheticMarker)
                event.postToPid(pid)
            }
            offset = end
            // Следующая часть не уходит, пока первая не появилась в том же поле.
            // Страница может переводить фокус из обработчика input/keydown.
            let inserted = String(decoding: units.prefix(offset), as: UTF16.self)
            let deadline = Date().addingTimeInterval(0.3)
            var delivered = false
            repeat {
                if let updated = Self.capture(), verifies(inserted, updated: updated),
                   offset == units.count || updated.selected.isEmpty {
                    delivered = true; break
                }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < deadline
            guard delivered else {
                kbLog("completion insertion: Unicode результат не подтверждён")
                return false
            }
        }
        kbLog("completion insertion: Unicode результат подтверждён")
        return true
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
