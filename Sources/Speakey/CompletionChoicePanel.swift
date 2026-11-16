import AppKit

/// Нумерованный список у каретки. Не меняет фокус исходного поля.
final class CompletionChoicePanel {
    static let shared = CompletionChoicePanel()
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }
    func show(_ choices: [String], selected: Int, caret: NSRect, title: String) {
        guard Thread.isMainThread, !choices.isEmpty else { return }
        let panel = self.panel ?? makePanel(); self.panel = panel
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = DS.itemGap
        body.edgeInsets = NSEdgeInsets(top: DS.detailRowInset, left: DS.detailRowInset, bottom: DS.detailRowInset, right: DS.detailRowInset)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: DS.detailCaptionSize, weight: .semibold)
        heading.textColor = .secondaryLabelColor; body.addArrangedSubview(heading)
        for (index, text) in choices.enumerated() {
            let label = NSTextField(labelWithString: "\(index + 1)  \(text.trimmingCharacters(in: .whitespaces))")
            label.font = .systemFont(ofSize: DS.detailFontSize, weight: selected == index ? .semibold : .regular)
            label.textColor = selected == index ? DS.coral : .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityIdentifier("completion.choice.\(index + 1)")
            body.addArrangedSubview(label)
        }
        let hint = NSTextField(labelWithString: L10n.autocomplete("choiceKeys"))
        hint.font = .systemFont(ofSize: DS.detailCaptionSize); hint.textColor = .secondaryLabelColor
        body.addArrangedSubview(hint)
        panel.contentView = body
        let size = body.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let width = min(DS.fieldMaxWidth + DS.contentMargin * 2, max(DS.fieldMaxWidth, size.width))
        let height = size.height
        let x = max(screen.minX, min(caret.minX, screen.maxX - width))
        let y = max(screen.minY, min(caret.minY - height - DS.itemGap, screen.maxY - height))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil) }
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .statusBar
        panel.hidesOnDeactivate = false; panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        return panel
    }
}
