import AppKit

/// Призрачный текст подсказки у каретки. Не активируется, не ловит мышь.
final class GhostSuggestionPanel {
    static let shared = GhostSuggestionPanel()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    var isVisible: Bool { panel?.isVisible ?? false }
    static var debugOnce = true

    /// `caret` в Cocoa-координатах. Обычный текст использует шрифт поля, если он доступен.
    func show(_ text: String, caret: NSRect, isCorrection: Bool, belowLine: Bool = false, typedPrefix: String = "", textFont: NSFont? = nil) {
        let work: () -> Void = { [self] in
            let p = panel ?? makePanel(); panel = p
            let fontSize = min(28, max(11, (caret.height * (belowLine ? 0.8 : 0.85)).rounded()))
            let font = belowLine ? NSFont.systemFont(ofSize: fontSize) : (textFont ?? NSFont.systemFont(ofSize: fontSize))
            label.font = font
            // Фиксированный средне-серый, а не secondaryLabelColor: тот берёт тему Speakey, а не поля,
            // и в тёмной теме светло-серая подсказка пропадала на белой странице Safari (12.11).
            let gray = NSColor(white: 0.52, alpha: 0.95)
            let value = NSMutableAttributedString(string: belowLine ? typedPrefix + text : (isCorrection ? "→ " + text : text),
                                                   attributes: [.font: font, .foregroundColor: gray])
            if belowLine, !typedPrefix.isEmpty {
                value.addAttribute(.foregroundColor, value: NSColor.labelColor,
                                   range: NSRange(location: 0, length: typedPrefix.utf16.count))
            }
            label.attributedStringValue = value
            label.sizeToFit()
            let size = label.frame.size
            let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) }?.visibleFrame
                ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let insetX: CGFloat = belowLine ? 8 : 0
            let insetY: CGFloat = belowLine ? 3 : 1
            let w = belowLine ? min(ceil(size.width) + insetX * 2, min(520, screen.width)) : ceil(size.width) + 2
            let h = ceil(size.height) + insetY * 2
            label.frame = NSRect(x: insetX, y: insetY, width: max(0, w - insetX * 2), height: ceil(size.height))
            label.lineBreakMode = belowLine ? .byTruncatingTail : .byClipping
            p.hasShadow = belowLine
            if let content = p.contentView {
                content.wantsLayer = true
                content.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let dark = content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    let background = dark ? NSColor.textBackgroundColor
                        : NSColor(srgbRed: 0.975, green: 0.975, blue: 0.972, alpha: 1)
                    content.layer?.backgroundColor = (belowLine ? background : .clear).cgColor
                    content.layer?.borderColor = NSColor.separatorColor.cgColor
                }
                content.layer?.cornerRadius = belowLine ? h / 2 : 0
                content.layer?.borderWidth = belowLine ? 0.5 : 0
                content.layer?.masksToBounds = true
            }

            // Убираем внутренний отступ NSTextField: видимый текст начинается у самой каретки.
            let x = belowLine ? max(screen.minX, min(caret.minX - insetX, screen.maxX - w))
                : caret.minX - label.alignmentRectInsets.left
            // У NSTextField есть собственные отступы и метрика базовой линии. Центр его рамки
            // не совпадает с базовой линией текста в редакторе, особенно у другого шрифта.
            let layout = NSLayoutManager()
            let baseline = caret.maxY - layout.defaultBaselineOffset(for: font)
            let inlineY = baseline - (label.frame.height - label.firstBaselineOffsetFromTop) - insetY
            let gap: CGFloat = 3
            let below = caret.minY - h - gap
            let preferredY = below >= screen.minY ? below : caret.maxY + gap
            let scale = NSScreen.screens.first { $0.frame.contains(caret.origin) }?.backingScaleFactor ?? 1
            let y = belowLine ? max(screen.minY, min(preferredY, screen.maxY - h)).rounded()
                : (inlineY * scale).rounded() / scale
            if UserDefaults.standard.bool(forKey: "ac.debugSkips") || Self.debugOnce {
                Self.debugOnce = false
                kbLog("ghost: режим=\(belowLine ? "плашка" : "строка") каретка \(caret.integral) панель y=\(Int(y)) h=\(Int(h)) шрифт \(Int(font.pointSize))")
            }
            p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
            if !belowLine {
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
