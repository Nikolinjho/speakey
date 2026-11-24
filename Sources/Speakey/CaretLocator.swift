import ApplicationServices
import AppKit

/// Экранное положение КАРЕТКИ ВВОДА ТЕКСТА (мигающего курсора) через Accessibility — чтобы плашка
/// «Слушаю» появлялась у места ввода, а не у курсора мыши. Работает в нативных полях (TextEdit, Notes,
/// Mail, Pages, поля Safari…). Electron/web (Chrome, VS Code, Slack) часто не отдают bounds каретки →
/// возвращаем nil, и вызывающий падает на позицию мыши. (автор 2026-06-30.)
enum CaretLocator {

    /// Только один символ возле каретки. Вызывается после проверки поля, вне колбэка клавиатуры.
    static func fontNearCaret(element: AXUIElement, range: CFRange, renderedHeight: CGFloat? = nil) -> NSFont? {
        guard range.location >= 0 else { return nil }
        var character = CFRange(location: max(0, range.location - 1), length: 1)
        guard let argument = AXValueCreate(.cfRange, &character) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                         argument, &raw) == .success,
              let text = raw as? NSAttributedString, text.length > 0 else { return nil }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        if let font = attributes[.font] as? NSFont, font.pointSize.isFinite, (1...200).contains(font.pointSize) { return font }
        guard let info = attributes[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any],
              let number = info[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber else { return nil }
        let size = CGFloat(number.doubleValue)
        guard size.isFinite, (1...200).contains(size) else { return nil }
        let name = info[kAXFontNameKey.takeUnretainedValue() as String] as? String
        let family = info[kAXFontFamilyKey.takeUnretainedValue() as String] as? String
        let font = name.flatMap { NSFont(name: $0, size: size) }
            ?? family.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size)
        // Chromium возвращает размер из CSS без масштаба страницы. Геометрия каретки
        // учитывает масштаб, но округляется и может отличаться из-за подстановки гарнитуры.
        guard let renderedHeight else { return font }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let scale = renderedHeight / lineHeight
        let renderedSize = size * scale
        guard abs(renderedHeight - lineHeight) > 1, (0.5...3).contains(scale),
              (1...200).contains(renderedSize) else { return font }
        return NSFont(descriptor: font.fontDescriptor, size: renderedSize) ?? font
    }

    /// Границы поля в той же системе координат, что и каретка.
    static func fieldScreenRect(element: AXUIElement) -> NSRect? {
        var pid: pid_t = 0
        if !Thread.isMainThread, AXUIElementGetPid(element, &pid) == .success, pid == getpid() {
            return DispatchQueue.main.sync { fieldScreenRect(element: element) }
        }
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return flipToCocoa(CGRect(origin: position, size: size))
    }

    /// Прямоугольник каретки в Cocoa-координатах (origin снизу-слева). nil — если недоступно.
    /// `preferCharBefore` — сначала правый край символа перед кареткой. Нужен призрачному тексту
    /// автодополнения: TextEdit для пустого диапазона в конце строки отдаёт прямоугольник на ~строку
    /// выше настоящей каретки (замер 12.11.2026), а прямоугольник символа точен. Диктовка остаётся
    /// на прежнем порядке — для неё важнее пустое поле, где символа перед кареткой нет.
    static func caretScreenRect(preferCharBefore: Bool = false, element focusedElement: AXUIElement? = nil) -> NSRect? {
        guard let element = focusedElement ?? AXFocusedElement.read(timeout: 0.25) else { return nil }

        // Диапазон выделения/каретки (каретка = длина 0 в позиции курсора).
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rr = rangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rr as! AXValue, .cfRange, &range) else { return nil }
        let loc = max(range.location, 0)

        // bounds диапазона — устойчиво: (1) сама каретка длины 0 (истинная позиция; многие поля
        // отдают её напрямую); (2) символ У каретки (loc,1); (3) символ ПЕРЕД кареткой (loc-1,1) →
        // каретка на его правом краю. Пункт 3 закрывает КЛЮЧЕВОЙ кейс диктовки: каретка в КОНЦЕ
        // текста (или поле пустое) — тогда (loc,1) за концом строки и падает.
        func bounds(_ l: Int, _ n: Int) -> CGRect? {
            var r = CFRange(location: l, length: n)
            guard l >= 0, let v = AXValueCreate(.cfRange, &r) else { return nil }
            var ref: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                    element, kAXBoundsForRangeParameterizedAttribute as CFString, v, &ref) == .success,
                  let rr = ref, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
            var q = CGRect.zero
            guard AXValueGetValue(rr as! AXValue, .cgRect, &q),
                  q.origin.x.isFinite, q.origin.y.isFinite, q.width.isFinite, q.height.isFinite,
                  q.height > 0 else { return nil }
            return q
        }

        var quartz: CGRect?
        if preferCharBefore, loc > 0, let before = bounds(loc - 1, 1), before.width > 0, before.width < 200 {
            quartz = CGRect(x: before.maxX, y: before.origin.y, width: 1, height: before.height)
        }
        if quartz == nil { quartz = bounds(loc, 0) }
        if quartz == nil { quartz = bounds(loc, 1) }
        if quartz == nil, loc > 0, let before = bounds(loc - 1, 1) {
            quartz = CGRect(x: before.maxX, y: before.origin.y, width: 1, height: before.height)
        }
        // Slack отдаёт нулевые AXBoundsForRange даже при доступном тексте. Диапазон
        // текстовых маркеров того же поля содержит настоящую геометрию каретки.
        // Для выделения это рамка всего текста, поэтому используем только пустой диапазон.
        if quartz == nil, range.length == 0 {
            var markerRange: CFTypeRef?
            var markerBounds: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
               let markerRange,
               AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString,
                                                          markerRange, &markerBounds) == .success,
               let rawBounds = markerBounds, CFGetTypeID(rawBounds) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(rawBounds as! AXValue, .cgRect, &rect),
                   rect.origin.x.isFinite, rect.origin.y.isFinite,
                   rect.width.isFinite, rect.height.isFinite, rect.width >= 0, rect.height > 0 {
                    quartz = rect
                }
            }
        }
        guard let q = quartz, q != .zero else { return nil }
        return flipToCocoa(q)
    }

    /// Quartz global (origin top-left главного экрана) → Cocoa (origin bottom-left главного экрана).
    private static func flipToCocoa(_ r: CGRect) -> NSRect {
        guard let main = NSScreen.screens.first else { return r }   // screens[0] = главный, origin (0,0) в Cocoa
        let mainHeight = main.frame.height
        return NSRect(x: r.origin.x, y: mainHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }
}
