import AppKit

final class NeuralLayoutSettingsView: NSStackView {
    private let settings: AppSettings
    private let presentation: NeuralLayoutPresentationStore
    private var observer: NSObjectProtocol?
    private var modeObserver: NSObjectProtocol?
    private let modes: [NeuralLayoutMode] = [.off, .observe, .assist]
    private let picker = NSPopUpButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let disclosure = NSButton()
    private let explanation = NSTextField(wrappingLabelWithString: "")

    init(settings: AppSettings, presentation: NeuralLayoutPresentationStore) {
        self.settings = settings
        self.presentation = presentation
        super.init(frame: .zero)
        orientation = .vertical; alignment = .width; spacing = 0

        let card = CardView()
        card.wantsLayer = true
        let body = NSStackView()
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 7
        body.edgeInsets = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            body.topAnchor.constraint(equalTo: card.topAnchor),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true

        let title = NSTextField(labelWithString: L10n.neural("title"))
        title.font = .systemFont(ofSize: 12)
        picker.addItems(withTitles: modes.map { L10n.neural($0.rawValue) })
        picker.autoenablesItems = false
        picker.controlSize = .small
        picker.font = .systemFont(ofSize: 11)
        picker.target = self; picker.action = #selector(selectMode)
        picker.setAccessibilityIdentifier("neural.mode")
        picker.setAccessibilityLabel(L10n.neural("title"))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [title, spacer, picker])
        row.alignment = .centerY; row.spacing = 8
        body.addArrangedSubview(row)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("neural.status")
        body.addArrangedSubview(statusLabel)

        disclosure.setButtonType(.onOff)
        disclosure.bezelStyle = .inline; disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.font = .systemFont(ofSize: 11)
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.target = self; disclosure.action = #selector(toggleExplanation)
        disclosure.setAccessibilityIdentifier("neural.details")
        disclosure.setContentHuggingPriority(.defaultLow, for: .horizontal)
        body.addArrangedSubview(disclosure)

        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.setAccessibilityIdentifier("neural.explanation")
        explanation.isHidden = true
        body.addArrangedSubview(explanation)
        for view in [row, statusLabel, disclosure, explanation] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -22).isActive = true
        }
        toggleExplanation()

        observer = presentation.notifications.addObserver(forName: NeuralLayoutPresentationStore.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        modeObserver = NotificationCenter.default.addObserver(forName: .neuralLayoutModeChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { presentation.notifications.removeObserver(observer) }
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    }

    @objc private func toggleExplanation() {
        let expanded = disclosure.state == .on
        explanation.isHidden = !expanded
        disclosure.title = (expanded ? "▾ " : "▸ ") + L10n.neural("details")
        disclosure.setAccessibilityValue(expanded ? "1" : "0")
    }

    @objc private func selectMode() {
        let mode = modes[picker.indexOfSelectedItem]
        guard mode != .assist || presentation.value.assistanceAvailable else { refresh(); return }
        settings.neuralLayoutMode = mode
        refresh()
    }

    private func refresh() {
        let value = presentation.value
        let selected = settings.neuralLayoutMode
        picker.selectItem(at: modes.firstIndex(of: selected)!)
        picker.item(at: 2)?.isEnabled = value.assistanceAvailable
        var lines: [String] = []
        switch value.status {
        case .off: lines.append(L10n.neural("stopped"))
        case .loading: lines.append(L10n.neural("loading"))
        case .ready: lines.append(L10n.neural("ready"))
        case .unavailable: lines.append(L10n.neural("unavailable") + (value.error ?? ""))
        }
        if value.status != .unavailable, let error = value.error { lines.append(L10n.neural("unavailable") + error) }
        if !value.assistanceAvailable { lines.append(L10n.neural("qualityShort")) }
        if selected == .assist && !value.assistanceAvailable {
            lines.append(L10n.neural("effective") + L10n.neural(value.effectiveMode.rawValue))
        }
        statusLabel.stringValue = lines.joined(separator: " · ")
        statusLabel.toolTip = !value.assistanceAvailable ? L10n.neural("quality") : nil
        explanation.stringValue = ["observeHelp", "assistHelp"].map(L10n.neural).joined(separator: "\n\n")
            + (!value.assistanceAvailable ? "\n\n" + L10n.neural("quality") : "")
    }
}
