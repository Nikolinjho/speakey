import AppKit

/// Призрачный текст подсказки у каретки. Не активируется, не ловит мышь.
final class GhostSuggestionPanel {
    static let shared = GhostSuggestionPanel()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    var isVisible: Bool { panel?.isVisible ?? false }
    static var debugOnce = true

    /// `caret` в Cocoa-координатах. Обычный текст использует шрифт поля, если он доступен.
    func show(_ text: String, caret: NSRect, isCorrection: Bool, belowLine: Bool = false,
              typedPrefix: String = "", textFont: NSFont? = nil, fieldBounds: NSRect? = nil) {
        let work: () -> Void = { [self] in
            let p = panel ?? makePanel()
            panel = p
            let display = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
            let screen = display?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let scale = display?.backingScaleFactor ?? 1
            let inlineFont = textFont ?? NSFont.systemFont(ofSize: min(28, max(11, (caret.height * 0.85).rounded())))
            let pillFont = NSFont.systemFont(ofSize: min(28, max(11, (caret.height * 0.8).rounded())))
            // Цвет не зависит от темы SpeaKey: подсказка рисуется поверх чужого поля.
            let gray = NSColor(white: 0.52, alpha: 0.95)
            let continuation = isCorrection ? "→ " + text : text
            let value = NSMutableAttributedString(string: belowLine ? typedPrefix + text : continuation,
                                                   attributes: [.font: belowLine ? pillFont : inlineFont, .foregroundColor: gray])
            if belowLine, !typedPrefix.isEmpty {
                value.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                   range: NSRange(location: 0, length: typedPrefix.utf16.count))
            }
            label.lineBreakMode = .byClipping
            label.attributedStringValue = value
            label.sizeToFit()
            let inlineX = caret.minX - label.alignmentRectInsets.left
            let inlineWidth = ceil(label.frame.width) + 2

            var left = ceil(screen.minX)
            var right = floor(screen.maxX)
            if !belowLine, let fieldBounds,
               fieldBounds.minX <= caret.minX, fieldBounds.minY < caret.maxY, fieldBounds.maxY > caret.minY {
                let fieldLeft = max(left, ceil(fieldBounds.minX))
                let fieldRight = min(right, floor(fieldBounds.maxX))
                if fieldRight > fieldLeft {
                    left = fieldLeft
                    right = fieldRight
                }
            }
            let usesPill = belowLine || ceil(inlineX) + inlineWidth > right
            if usesPill, !belowLine {
                value.addAttribute(.font, value: pillFont, range: NSRange(location: 0, length: value.length))
                label.attributedStringValue = value
                label.sizeToFit()
            }

            let size = label.frame.size
            let insetX: CGFloat = usesPill ? min(8, (right - left) / 4) : 0
            let insetY: CGFloat = usesPill ? 3 : 1
            let w = usesPill ? min(ceil(size.width) + insetX * 2, 520, right - left) : inlineWidth
            let h = ceil(size.height) + insetY * 2
            label.frame = NSRect(x: insetX, y: insetY, width: w - insetX * 2, height: ceil(size.height))
            label.lineBreakMode = usesPill ? .byTruncatingTail : .byClipping
            p.hasShadow = usesPill
            if let content = p.contentView {
                content.wantsLayer = true
                content.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let dark = content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    let background = dark ? NSColor.textBackgroundColor
                        : NSColor(srgbRed: 0.975, green: 0.975, blue: 0.972, alpha: 1)
                    content.layer?.backgroundColor = (usesPill ? background : .clear).cgColor
                    content.layer?.borderColor = NSColor.separatorColor.cgColor
                }
                content.layer?.cornerRadius = usesPill ? h / 2 : 0
                content.layer?.borderWidth = usesPill ? 0.5 : 0
                content.layer?.masksToBounds = true
            }

            let x = usesPill ? max(left, min((caret.minX - insetX).rounded(), right - w)) : inlineX
            let layout = NSLayoutManager()
            let baseline = caret.maxY - layout.defaultBaselineOffset(for: inlineFont)
            let inlineY = baseline - (label.frame.height - label.firstBaselineOffsetFromTop) - insetY
            let gap: CGFloat = 3
            let below = caret.minY - h - gap
            let preferredY = below >= screen.minY ? below : caret.maxY + gap
            let y = usesPill ? max(screen.minY, min(preferredY, screen.maxY - h)).rounded()
                : (inlineY * scale).rounded() / scale
            if UserDefaults.standard.bool(forKey: "ac.debugSkips") || Self.debugOnce {
                Self.debugOnce = false
                let font = usesPill ? pillFont : inlineFont
                kbLog("ghost: режим=\(usesPill ? "плашка" : "строка") каретка \(caret.integral) панель y=\(Int(y)) h=\(Int(h)) шрифт \(Int(font.pointSize))")
            }
            p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            if !usesPill {
                // NSWindow округляет рамку до целых пунктов. Остаток переносим в положение
                // самого текста, чтобы на Retina сохранить совпадение до физического пикселя.
                let textX = (caret.minX * scale).rounded() / scale
                let textBaseline = (baseline * scale).rounded() / scale
                label.setFrameOrigin(NSPoint(x: textX - p.frame.minX - label.alignmentRectInsets.left,
                                             y: textBaseline - p.frame.minY - (label.frame.height - label.firstBaselineOffsetFromTop)))
            }
            p.invalidateShadow()
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
