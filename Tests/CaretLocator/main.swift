import AppKit
import ApplicationServices

// Подменяется только внешний AX: воспроизводим ответы Slack без доступа к чужим окнам.
let fixture = AXUIElementCreateApplication(getpid())
var numericBounds = CGRect.zero
var markerBounds = CGRect(x: 646, y: 739, width: 0, height: 18)
var markerAvailable = true
var selectionLength = 0
var systemUnavailable = false
var reportedPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? getpid()
var styledAttributes: [NSAttributedString.Key: Any]? = [NSAttributedString.Key("AXFont"): ["AXFontName": "Helvetica", "AXFontSize": 20]]
func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString,
                                  _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    switch attribute as String {
    case "AXFocusedUIElement":
        if systemUnavailable, CFEqual(element, AXUIElementCreateSystemWide()) { return .cannotComplete }
        value.pointee = fixture
    case "AXSelectedTextRange":
        var range = CFRange(location: 29, length: selectionLength)
        value.pointee = AXValueCreate(.cfRange, &range)
    case "AXSelectedTextMarkerRange" where markerAvailable: value.pointee = "marker" as CFString
    default: return .attributeUnsupported
    }
    return .success
}
func AXUIElementCopyParameterizedAttributeValue(_ element: AXUIElement, _ attribute: CFString,
                                               _ parameter: CFTypeRef, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError {
    if attribute as String == "AXAttributedStringForRange" {
        guard let styledAttributes else { return .parameterizedAttributeUnsupported }
        value.pointee = NSAttributedString(string: "я", attributes: styledAttributes)
        return .success
    }
    var rect: CGRect
    switch attribute as String {
    case "AXBoundsForRange": rect = numericBounds
    case "AXBoundsForTextMarkerRange" where markerAvailable: rect = markerBounds
    default: return .parameterizedAttributeUnsupported
    }
    value.pointee = AXValueCreate(.cgRect, &rect)
    return .success
}
func AXUIElementGetPid(_ element: AXUIElement, _ pid: UnsafeMutablePointer<pid_t>) -> AXError {
    pid.pointee = reportedPID
    return .success
}
func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
    if attribute as String == "AXEnhancedUserInterface" { markerAvailable = true }
    return .notImplemented
}
var failures = 0
func check(_ name: String, _ passed: Bool) {
    print("\(passed ? "PASS" : "FAIL"): \(name)")
    if !passed { failures += 1 }
}
check("Нулевая геометрия Slack заменяется координатами текстового маркера",
      CaretLocator.caretScreenRect(preferCharBefore: true)?.height == 18)
markerAvailable = false
check("Без обоих источников координат возвращается nil", CaretLocator.caretScreenRect() == nil)
markerAvailable = true
markerBounds = .zero
check("Нулевой прямоугольник маркера отклоняется", CaretLocator.caretScreenRect() == nil)
markerBounds = CGRect(x: CGFloat.nan, y: 739, width: 0, height: 18)
check("Некорректные координаты маркера отклоняются", CaretLocator.caretScreenRect() == nil)
markerBounds = CGRect(x: 646, y: 739, width: 0, height: 18)
selectionLength = 2
check("Рамка выделения не выдаётся за каретку", CaretLocator.caretScreenRect() == nil)
selectionLength = 0
numericBounds = CGRect(x: 100, y: 200, width: 8, height: 22)
check("Прежняя геометрия символа имеет приоритет",
      CaretLocator.caretScreenRect(preferCharBefore: true)?.origin.x == 108)
systemUnavailable = true
check("При отказе системного AX поле читается через активное приложение",
      CaretLocator.caretScreenRect(preferCharBefore: true)?.origin.x == 108)
numericBounds = .zero
markerAvailable = false
check("До подготовки Electron геометрия недоступна", CaretLocator.caretScreenRect() == nil)
AXFocusedElement.prepareElectron(pid: reportedPID)
check("Подготовка Electron открывает геометрию даже при ошибке setter",
      CaretLocator.caretScreenRect()?.height == 18)
reportedPID = -1
check("Поле чужого процесса отклоняется", CaretLocator.caretScreenRect() == nil)
systemUnavailable = false
let styleRange = CFRange(location: 29, length: 0)
check("Читается шрифт исходного поля", CaretLocator.fontNearCaret(element: fixture, range: styleRange)?.fontName == "Helvetica")
check("Сохраняется размер шрифта исходного поля", CaretLocator.fontNearCaret(element: fixture, range: styleRange)?.pointSize == 20)
styledAttributes = [NSAttributedString.Key("AXFont"): ["AXFontSize": 15]]
check("Slack без имени шрифта сохраняет его точный размер", CaretLocator.fontNearCaret(element: fixture, range: styleRange)?.pointSize == 15)
styledAttributes = [.font: NSFont(name: "Helvetica", size: 17)!]
check("Нативный атрибут шрифта сохраняется", CaretLocator.fontNearCaret(element: fixture, range: styleRange)?.pointSize == 17)
styledAttributes = [NSAttributedString.Key("AXFont"): ["AXFontSize": Double.nan]]
check("Некорректный размер не создаёт шрифт", CaretLocator.fontNearCaret(element: fixture, range: styleRange) == nil)
styledAttributes = nil
check("Недоступная типографика оставляет прежний запасной вариант", CaretLocator.fontNearCaret(element: fixture, range: styleRange) == nil)
print("caret: \(failures == 0 ? "OK" : "FAIL"), ошибок: \(failures)")
exit(failures == 0 ? 0 : 1)
