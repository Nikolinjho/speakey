import AppKit

final class NeuralLayoutSettingsView: NSStackView {
    private let settings: AppSettings
    private let presentation: NeuralLayoutPresentationStore
    private var observer: NSObjectProtocol?
    private var modeObserver: NSObjectProtocol?
    private var buttons: [NeuralLayoutMode: NSButton] = [:]
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: AppSettings, presentation: NeuralLayoutPresentationStore) {
        self.settings = settings
        self.presentation = presentation
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        let title = NSTextField(labelWithString: L10n.neural("title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        addArrangedSubview(title)
        for (index, mode) in [NeuralLayoutMode.off, .observe, .assist].enumerated() {
            let button = NSButton(radioButtonWithTitle: L10n.neural(mode.rawValue), target: self, action: #selector(selectMode))
            button.tag = index
            button.setAccessibilityIdentifier("neural.mode." + mode.rawValue)
            buttons[mode] = button; addArrangedSubview(button)
        }
        for key in ["observeHelp", "assistHelp"] {
            let help = NSTextField(wrappingLabelWithString: L10n.neural(key))
            help.textColor = .secondaryLabelColor; help.font = .systemFont(ofSize: 12)
            addArrangedSubview(help)
            help.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        statusLabel.setAccessibilityIdentifier("neural.status")
        statusLabel.font = .systemFont(ofSize: 12)
        addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        observer = presentation.notifications.addObserver(forName: NeuralLayoutPresentationStore.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        modeObserver = NotificationCenter.default.addObserver(forName: .neuralLayoutModeChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let observer { presentation.notifications.removeObserver(observer) }
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    }
    @objc private func selectMode(_ sender: NSButton) {
        settings.neuralLayoutMode = [NeuralLayoutMode.off, .observe, .assist][sender.tag]
        refresh()
    }
    private func refresh() {
        let value = presentation.value
        let selected = settings.neuralLayoutMode
        for (mode, button) in buttons { button.state = mode == selected ? .on : .off }
        buttons[.assist]?.isEnabled = value.assistanceAvailable
        var lines: [String] = []
        switch value.status {
        case .off: lines.append(L10n.neural("stopped"))
        case .loading: lines.append(L10n.neural("loading"))
        case .ready: lines.append(L10n.neural("ready"))
        case .unavailable: lines.append(L10n.neural("unavailable") + (value.error ?? ""))
        }
        if value.status != .unavailable, let error = value.error { lines.append(L10n.neural("unavailable") + error) }
        if !value.assistanceAvailable { lines.append(L10n.neural("quality")) }
        if selected == .assist && !value.assistanceAvailable {
            lines.append(L10n.neural("effective") + L10n.neural(value.effectiveMode.rawValue))
        }
        statusLabel.stringValue = lines.joined(separator: "\n")
    }
}
