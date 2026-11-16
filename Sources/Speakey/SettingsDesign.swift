import AppKit
import QuartzCore

/// Размеры компактного окна и общие цвета настроек.
enum DS {
    static let sidebarWidth: CGFloat = 172
    static let rowHeight: CGFloat = 30
    static let rowGap: CGFloat = 2
    static let pillInsetH: CGFloat = 8
    static let rowLeadingInset: CGFloat = 10
    static let iconTextGap: CGFloat = 7
    static let iconPointSize: CGFloat = 13
    static let pillRadius: CGFloat = 6
    static let contentMaxWidth: CGFloat = 528
    static let contentWidth: CGFloat = 528
    static let contentMargin: CGFloat = 20
    static let brandTopPad: CGFloat = 10
    static let brandIconSize: CGFloat = 32
    static let sidebarListGap: CGFloat = 12
    static let titlebarHeight: CGFloat = 32
    static let brandBottomPad: CGFloat = 8
    static let simpleBottomPad: CGFloat = 22
    // Правое поле включает место постоянной полосы прокрутки.
    static let minWindowWidth: CGFloat = 760
    static let defaultWindowHeight: CGFloat = 560
    static let simpleContentWidth: CGFloat = 560
    static let simpleWindowWidth: CGFloat = simpleContentWidth + contentMargin * 2
    static let sectionGap: CGFloat = 12
    static let itemGap: CGFloat = 6
    static let fieldMaxWidth: CGFloat = 300
    static let detailFontSize: CGFloat = 12
    static let detailCaptionSize: CGFloat = 11
    static let detailRowInset: CGFloat = 11
    static let detailVerticalInset: CGFloat = 5
    static let detailMinimumRowHeight: CGFloat = 35
    static let corpusWindowWidth: CGFloat = 820
    static let corpusWindowHeight: CGFloat = 580
    static let corpusListHeight: CGFloat = 220
    static let corpusDateWidth: CGFloat = 145
    static let corpusSourceWidth: CGFloat = 160
    static let corpusPreviewWidth: CGFloat = 380
    static let coral = NSColor(srgbRed: 1.0, green: 122.0/255.0, blue: 89.0/255.0, alpha: 1)
    static let graphite = NSColor(srgbRed: 0x1C/255.0, green: 0x1B/255.0, blue: 0x1A/255.0, alpha: 1)
}


final class CardView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        // ⚠️ В СВЕТЛОЙ ТЕМЕ У НАС БЫЛО ИНВЕРТИРОВАНО ОТНОСИТЕЛЬНО macOS (замечание автора 29.07 со
        // скриншотом системных настроек). У системы: страница белая, группы чуть СЕРЕЕ. У нас было
        // наоборот — серая страница и белые карточки. В тёмной теме наша схема с системой совпадала,
        // поэтому годами и не бросалось в глаза: баг жил ровно в одной теме.
        // Берём НЕ фиксированный серый, а полупрозрачный чёрный поверх белой страницы: так оттенок
        // следует за «Увеличить контраст» и прочими настройками универсального доступа.
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.075)
                                        : NSColor.black.withAlphaComponent(0.035)).cgColor
        layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.10)
                                    : NSColor.black.withAlphaComponent(0.06)).cgColor
    }
}
