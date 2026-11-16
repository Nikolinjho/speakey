import AppKit
import ApplicationServices

/// Slack может не отвечать системному AX, но отдавать поле через собственный процесс.
/// Проверяем PID, чтобы запасной путь не прочитал поле другого приложения.
enum AXFocusedElement {
    /// Electron без расширенного режима отдаёт нулевую геометрию текстовых маркеров.
    /// Вызывать только для Electron, вне главной очереди и колбэка клавиатуры.
    static func prepareElectron(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Slack может сообщить об ошибке, уже применив значение. Не прерываем чтение.
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    static func read(pid: pid_t? = nil, timeout: Float = 0.05) -> AXUIElement? {
        let expectedPID = pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        func focused(in root: AXUIElement) -> AXUIElement? {
            AXUIElementSetMessagingTimeout(root, timeout)
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
                  let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            let element = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(element, timeout)
            if let expectedPID {
                var actualPID: pid_t = 0
                guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == expectedPID else { return nil }
            }
            return element
        }
        if let element = focused(in: AXUIElementCreateSystemWide()) { return element }
        guard let expectedPID else { return nil }
        return focused(in: AXUIElementCreateApplication(expectedPID))
    }
}
