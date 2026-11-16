import AppKit

/// Настройки приложений: наследование видно отдельно от текущего значения.
final class AutocompleteAppsView: NSStackView, NSSearchFieldDelegate {
    private let store: AutocompleteAppStore
    private let corpus: PersonalCorpus
    private let openCorpus: (String?) -> Void
    private let search = NSSearchField()
    private let list = NSStackView()
    private var fields: [NSTextField: String] = [:]
    private var counts: [String: Int] = [:]
    private var countLabels: [String: NSTextField] = [:]
    private var observer: NSObjectProtocol?
    private var controlsObserver: NSObjectProtocol?
    private var choices: [NSPopUpButton] = []

    init(store: AutocompleteAppStore = .shared, corpus: PersonalCorpus = .shared,
         openCorpus: @escaping (String?) -> Void) {
        self.store = store; self.corpus = corpus; self.openCorpus = openCorpus
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = DS.itemGap
        search.placeholderString = L10n.autocomplete("appsSearch")
        search.setAccessibilityIdentifier("ac.apps.search")
        search.setAccessibilityLabel(L10n.autocomplete("appsSearch"))
        search.delegate = self
        addArrangedSubview(search)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = DS.itemGap
        addArrangedSubview(list)
        let add = NSButton(title: L10n.autocomplete("addApp"), target: self, action: #selector(addApp))
        add.bezelStyle = .rounded; add.controlSize = .small
        add.setAccessibilityIdentifier("ac.addApp")
        let footer = NSStackView(views: [add, NSView()])
        footer.orientation = .horizontal; footer.alignment = .centerY
        addArrangedSubview(footer)
        for child in arrangedSubviews { child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        rebuild()
        observer = NotificationCenter.default.addObserver(forName: PersonalCorpus.changed, object: corpus, queue: .main) { [weak self] _ in self?.refreshCounts() }
        controlsObserver = NotificationCenter.default.addObserver(forName: AutocompletePrefs.controlsChanged, object: nil, queue: .main) { [weak self] _ in self?.refreshInheritance() }
        refreshCounts()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let controlsObserver { NotificationCenter.default.removeObserver(controlsObserver) }
    }

    private func appName(_ bid: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else { return bid }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func row(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: DS.detailFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = DS.itemGap
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: DS.detailMinimumRowHeight).isActive = true
        return row
    }

    private func choice(_ bid: String, key: String, value: Bool?, inherited: Bool, excluded: Bool) -> NSPopUpButton {
        let popup = NSPopUpButton()
        let effective = L10n.autocomplete(inherited ? "setting.on" : "setting.off")
        popup.addItems(withTitles: [String(format: L10n.autocomplete("setting.inherit"), effective),
                                   L10n.autocomplete("setting.on"), L10n.autocomplete("setting.off")])
        popup.selectItem(at: value.map { $0 ? 1 : 2 } ?? 0)
        popup.controlSize = .small; popup.font = .systemFont(ofSize: DS.detailFontSize)
        popup.identifier = NSUserInterfaceItemIdentifier("\(key):\(bid)")
        popup.setAccessibilityIdentifier("ac.app.\(bid).\(key)")
        popup.setAccessibilityLabel(appName(bid) + ": " + L10n.autocomplete("app.\(key)"))
        popup.target = self; popup.action = #selector(choiceChanged(_:)); popup.isEnabled = !excluded
        choices.append(popup)
        return popup
    }

    private func refreshInheritance() {
        for popup in choices {
            guard let parts = popup.identifier?.rawValue.split(separator: ":", maxSplits: 1), parts.count == 2 else { continue }
            let bid = String(parts[1])
            let inherited: Bool
            switch parts[0] {
            case "tab": inherited = !AutocompleteAppStore.hardExcluded.contains(bid) && AutocompletePrefs.tabEnabled
            case "enabled": inherited = !AutocompleteAppStore.hardExcluded.contains(bid) && !AutocompleteAppStore.offByDefault.contains(bid)
            default: inherited = !AutocompleteAppStore.hardExcluded.contains(bid)
            }
            popup.item(at: 0)?.title = String(format: L10n.autocomplete("setting.inherit"), L10n.autocomplete(inherited ? "setting.on" : "setting.off"))
        }
    }

    private func rebuild() {
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        fields.removeAll(); countLabels.removeAll(); choices.removeAll()
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = store.configuredApps.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) || appName($0).localizedCaseInsensitiveContains(query) }
        if apps.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.autocomplete(query.isEmpty ? "appsEmpty" : "appsNoMatches"))
            empty.font = .systemFont(ofSize: DS.detailFontSize); empty.textColor = .secondaryLabelColor
            empty.setAccessibilityIdentifier("ac.apps.empty")
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        for bid in apps {
            let excluded = AutocompleteAppStore.hardExcluded.contains(bid)
            let body = NSStackView()
            body.orientation = .vertical; body.alignment = .leading; body.spacing = DS.itemGap
            body.edgeInsets = NSEdgeInsets(top: DS.detailVerticalInset, left: DS.detailRowInset,
                                          bottom: DS.detailVerticalInset, right: DS.detailRowInset)
            let title = NSTextField(labelWithString: appName(bid))
            title.font = .systemFont(ofSize: DS.detailFontSize, weight: .semibold)
            title.alignment = .left
            body.addArrangedSubview(title)
            if excluded {
                let note = NSTextField(labelWithString: L10n.autocomplete("appAlwaysOff"))
                note.font = .systemFont(ofSize: DS.detailCaptionSize); note.textColor = .secondaryLabelColor
                body.addArrangedSubview(note)
            }
            body.addArrangedSubview(row(L10n.autocomplete("app.enabled"), control: choice(bid, key: "enabled", value: store.enabledOverride(bid),
                inherited: !excluded && !AutocompleteAppStore.offByDefault.contains(bid), excluded: excluded)))
            body.addArrangedSubview(row(L10n.autocomplete("app.record"), control: choice(bid, key: "record", value: store.recordOverride(bid), inherited: !excluded, excluded: excluded)))
            body.addArrangedSubview(row(L10n.autocomplete("app.tab"), control: choice(bid, key: "tab", value: store.tabOverride(bid), inherited: !excluded && AutocompletePrefs.tabEnabled, excluded: excluded)))
            let instruction = NSTextField(string: store.instruction(bid))
            instruction.placeholderString = L10n.autocomplete("appInstruction")
            instruction.font = .systemFont(ofSize: DS.detailFontSize); instruction.delegate = self
            instruction.setAccessibilityIdentifier("ac.app.\(bid).instruction")
            instruction.setAccessibilityLabel(appName(bid) + ": " + L10n.autocomplete("appInstruction"))
            instruction.isEnabled = !excluded; fields[instruction] = bid
            body.addArrangedSubview(instruction)
            let count = NSTextField(labelWithString: "")
            count.font = .systemFont(ofSize: DS.detailCaptionSize); countLabels[bid] = count
            let inspect = NSButton(title: L10n.autocomplete("corpusBrowse"), target: self, action: #selector(inspectApp(_:)))
            inspect.identifier = NSUserInterfaceItemIdentifier(bid)
            inspect.setAccessibilityIdentifier("ac.app.\(bid).corpus")
            inspect.bezelStyle = .rounded; inspect.controlSize = .small
            body.addArrangedSubview(row("", control: NSStackView(views: [count, inspect])))
            for child in body.arrangedSubviews {
                child.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -DS.detailRowInset * 2).isActive = true
            }
            let card = CardView(); card.wantsLayer = true; body.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(body)
            NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: card.leadingAnchor), body.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                                         body.topAnchor.constraint(equalTo: card.topAnchor), body.bottomAnchor.constraint(equalTo: card.bottomAnchor)])
            list.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        updateCounts()
    }

    private func updateCounts() {
        for (bid, label) in countLabels { label.stringValue = String(format: L10n.autocomplete("corpusCount"), counts[bid] ?? 0) }
    }
    private func refreshCounts() {
        PersonalCorpus.workQueue.async { [weak self] in
            guard let self else { return }
            let counts = self.corpus.snapshot().sourceCounts
            DispatchQueue.main.async { [weak self] in self?.counts = counts; self?.updateCounts() }
        }
    }
    @objc private func choiceChanged(_ popup: NSPopUpButton) {
        guard let parts = popup.identifier?.rawValue.split(separator: ":", maxSplits: 1), parts.count == 2 else { return }
        let bid = String(parts[1])
        let value: Bool? = popup.indexOfSelectedItem == 0 ? nil : popup.indexOfSelectedItem == 1
        switch parts[0] {
        case "enabled": store.setEnabled(bid, value)
        case "record": store.setRecordAllowed(bid, value)
        case "tab": store.setTabEnabled(bid, value)
        default: break
        }
    }
    @objc private func inspectApp(_ button: NSButton) { openCorpus(button.identifier?.rawValue) }
    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.message = L10n.autocomplete("addAppMessage")
        guard panel.runModal() == .OK, let url = panel.url, let bid = Bundle(url: url)?.bundleIdentifier else { return }
        store.register(bid); rebuild()
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { rebuild(); return }
        if let field = notification.object as? NSTextField, let bid = fields[field] { store.setInstruction(bid, field.stringValue) }
    }
}
