import AppKit

/// Призрачный текст подсказки у каретки. Не активируется, не ловит мышь.
final class GhostSuggestionPanel {
    static let shared = GhostSuggestionPanel()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    var isVisible: Bool { panel?.isVisible ?? false }
    static var debugOnce = true

    /// `caret` в Cocoa-координатах. Шрифт по высоте каретки (11...28 pt).
    func show(_ text: String, caret: NSRect, isCorrection: Bool) {
        let work: () -> Void = { [self] in
            let p = panel ?? makePanel(); panel = p
            let fontSize = min(28, max(11, (caret.height * 0.85).rounded()))
            let font = NSFont.systemFont(ofSize: fontSize)
            label.font = font
            label.textColor = .secondaryLabelColor
            label.stringValue = isCorrection ? "→ " + text : text
            label.sizeToFit()
            let size = label.frame.size
            let w = ceil(size.width) + 2, h = ceil(size.height)
            label.frame = NSRect(x: 1, y: 0, width: ceil(size.width), height: h)

            // Прямоугольник символа (ширина > 2) -> правый край; каретка -> её x.
            let x = caret.maxX + 1
            // Базовая линия: у каретки низ ~ базовая линия минус спуск; ставим низ лейбла так, чтобы
            // его базовая линия (низ + |descender|) совпала с низом каретки + её спуск.
            // Центр строки лейбла — на центр каретки: базовые линии разных шрифтов совпадают с точностью
            // до пикселя, а ошибиться на строку так нельзя.
            let y = (caret.midY - h / 2).rounded()
            if ProcessInfo.processInfo.environment["SPEAKEY_GHOST_DEBUG"] != nil || Self.debugOnce {
                Self.debugOnce = false
                kbLog("ghost: каретка \(caret.integral) панель y=\(Int(y)) h=\(Int(h)) шрифт \(Int(fontSize))")
            }
            p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            p.orderFrontRegardless()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func hide() {
        let work: () -> Void = { [self] in panel?.orderOut(nil) }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func makePanel() -> NSPanel {
        let p = GhostPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 20),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Флаг перед уровнем: сеттер isFloatingPanel сбрасывает уровень на .floating.
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        let content = NSView(frame: p.contentRect(forFrameRect: p.frame))
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.lineBreakMode = .byClipping
        content.addSubview(label)
        p.contentView = content
        return p
    }
}

private final class GhostPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
