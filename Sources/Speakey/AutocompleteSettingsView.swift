import AppKit

/// Раздел настроек «Автодополнение». Отдельный NSStackView по образцу NeuralLayoutSettingsView:
/// строки и карточки повторяют оформление SettingsWindow (CardView, hairline, 12/11 pt).
final class AutocompleteSettingsView: NSStackView, NSTextViewDelegate, NSTextFieldDelegate {
    private let prefsModels = CompletionModels.all
    private let wordsOptions = [3, 6, 10]
    private let pauseOptions = [80, 120, 200, 350]
    private let acceptAllOptions = [-1, 10, 50]
    private let recordOptions: [AutocompleteRecordMode] = [.off, .accepted, .all]

    private let modelPopup = NSPopUpButton()
    private let modelStatus = NSTextField(labelWithString: "")
    private let downloadButton = NSButton()
    private let deleteButton = NSButton()
    private let progress = NSProgressIndicator()
    private var downloading = false
    private let corpusCount = NSTextField(labelWithString: "")
    private let appsBox = NSStackView()
    private let aboutText = NSTextView()
    private var timer: Timer?
    private var instructionFields: [NSTextField: String] = [:]

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .width; spacing = DS.itemGap
        build()
        refreshModel()
        refreshCorpus()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        // Состояние помощника меняется само (запуск, сбой, выгрузка по простою) — опрашиваем раз в секунду.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshModel(); self?.refreshCorpus()
        }
    }

    // MARK: - Сборка

    private func build() {
        let title = NSTextField(labelWithString: L10n.autocomplete("title"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .left
        addArrangedSubview(title)
        addArrangedSubview(gap(2))

        addArrangedSubview(card([
            switchRow(L10n.autocomplete("main"), L10n.autocomplete("mainSub"),
                      AutocompletePrefs.enabled, #selector(toggleEnabled(_:)), key: "ac.enabled")
        ]))

        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("modelTitle")))
        addArrangedSubview(card([modelRow()]))

        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("behaviorTitle")))
        addArrangedSubview(card([
            popupRow(L10n.autocomplete("length"), nil,
                     wordsOptions.map { L10n.autocomplete("words\($0)") },
                     wordsOptions.firstIndex(of: AutocompletePrefs.maxWords) ?? 1,
                     #selector(wordsChanged(_:)), key: "ac.maxWords"),
            popupRow(L10n.autocomplete("pause"), L10n.autocomplete("pauseSub"),
                     pauseOptions.map { String(format: L10n.autocomplete("ms"), $0) },
                     pauseOptions.firstIndex(of: AutocompletePrefs.pauseMs) ?? 1,
                     #selector(pauseChanged(_:)), key: "ac.pause"),
            popupRow(L10n.autocomplete("acceptAll"), L10n.autocomplete("keysSub"),
                     acceptAllOptions.map { L10n.autocomplete("acceptAll\($0)") },
                     acceptAllOptions.firstIndex(of: AutocompletePrefs.acceptAllKeyCode) ?? 0,
                     #selector(acceptAllChanged(_:)), key: "ac.acceptAll"),
            switchRow(L10n.autocomplete("typo"), L10n.autocomplete("typoSub"),
                      AutocompletePrefs.typoFix, #selector(toggleTypo(_:)), key: "ac.typo"),
            switchRow(L10n.autocomplete("battery"), L10n.autocomplete("batterySub"),
                      AutocompletePrefs.batteryLight, #selector(toggleBattery(_:)), key: "ac.battery")
        ]))

        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("personalTitle")))
        addArrangedSubview(card([
            popupRow(L10n.autocomplete("record"), L10n.autocomplete("recordSub"),
                     recordOptions.map { L10n.autocomplete("record.\($0.rawValue)") },
                     recordOptions.firstIndex(of: AutocompletePrefs.recordMode) ?? 0,
                     #selector(recordChanged(_:)), key: "ac.record"),
            popupRow(L10n.autocomplete("strength"), L10n.autocomplete("strengthSub"),
                     (0...3).map { L10n.autocomplete("strength\($0)") },
                     min(3, max(0, AutocompletePrefs.personalStrength)),
                     #selector(strengthChanged(_:)), key: "ac.strength"),
            corpusRow(),
            aboutRow()
        ]))

        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("appsTitle")))
        appsBox.orientation = .vertical; appsBox.alignment = .width; appsBox.spacing = 0
        addArrangedSubview(card([appsBox]))
        rebuildApps()
        addArrangedSubview(note(L10n.autocomplete("appsSub")))

        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("contextTitle")))
        addArrangedSubview(card([
            switchRow(L10n.autocomplete("screen"), L10n.autocomplete("screenSub"),
                      AutocompletePrefs.useScreen, #selector(toggleScreen(_:)), key: "ac.screen"),
            switchRow(L10n.autocomplete("clipboard"), L10n.autocomplete("clipboardSub"),
                      AutocompletePrefs.useClipboard, #selector(toggleClipboard(_:)), key: "ac.clipboard"),
            switchRow(L10n.autocomplete("dictation"), L10n.autocomplete("dictationSub"),
                      AutocompletePrefs.dictationContext, #selector(toggleDictation(_:)), key: "ac.dictation")
        ]))

        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("tipTitle")))
        let tipButton = button(L10n.autocomplete("tipOpen"), #selector(openKeyboardSettings))
        addArrangedSubview(card([
            plainRow(L10n.autocomplete("tip"), trailing: tipButton)
        ]))
    }

    // MARK: - Строки

    private func eyebrow(_ t: String) -> NSView { DetailVC.eyebrowLabel(t) }

    private func gap(_ h: CGFloat) -> NSView {
        let v = NSView(); v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    private func note(_ t: String) -> NSTextField {
        let l = WrappingLabel(string: t)
        l.font = .systemFont(ofSize: 11); l.textColor = .tertiaryLabelColor
        return l
    }

    private func small(_ c: NSControl) {
        c.controlSize = .small; c.font = .systemFont(ofSize: 12)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded; small(b)
        return b
    }

    private func card(_ rows: [NSView]) -> CardView {
        let c = CardView(); c.wantsLayer = true
        let v = NSStackView()
        v.orientation = .vertical; v.alignment = .width; v.spacing = 0
        v.translatesAutoresizingMaskIntoConstraints = false
        for (i, r) in rows.enumerated() {
            if i > 0 { v.addArrangedSubview(hairline()) }
            v.addArrangedSubview(r)
        }
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            v.topAnchor.constraint(equalTo: c.topAnchor),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor)
        ])
        return c
    }

    private func hairline() -> NSView {
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = HairlineView(); line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor)
        ])
        return wrap
    }

    /// Заголовок + подпись слева (подпись переносится), контрол справа.
    private func row(_ title: String, _ subtitle: String?, trailing: NSView?, key: String? = nil) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 12); l.textColor = .labelColor
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var textViews: [NSView] = [l]
        if let subtitle {
            let s = WrappingLabel(string: subtitle)
            s.font = .systemFont(ofSize: 11); s.textColor = .secondaryLabelColor
            textViews.append(s)
        }
        let col = NSStackView(views: textViews)
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
        col.setClippingResistancePriority(.required, for: .vertical)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var items: [NSView] = [col, spacer]
        if let trailing {
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            items.append(trailing)
        }
        let r = NSStackView(views: items)
        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
        r.edgeInsets = NSEdgeInsets(top: 5, left: 11, bottom: 5, right: 11)
        r.heightAnchor.constraint(greaterThanOrEqualToConstant: 35).isActive = true
        r.setClippingResistancePriority(.required, for: .vertical)
        if let key { r.identifier = NSUserInterfaceItemIdentifier(key) }
        return r
    }

    private func plainRow(_ text: String, trailing: NSView?) -> NSView {
        let s = WrappingLabel(string: text)
        s.font = .systemFont(ofSize: 12); s.textColor = .labelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        var items: [NSView] = [s, spacer]
        if let trailing { items.append(trailing) }
        let r = NSStackView(views: items)
        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
        r.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        return r
    }

    private func switchRow(_ title: String, _ subtitle: String?, _ on: Bool, _ action: Selector, key: String) -> NSView {
        let sw = NSSwitch(); sw.state = on ? .on : .off; sw.target = self; sw.action = action
        sw.controlSize = .small
        sw.setAccessibilityIdentifier(key); sw.setAccessibilityLabel(title)
        return row(title, subtitle, trailing: sw, key: key)
    }

    private func popupRow(_ title: String, _ subtitle: String?, _ items: [String], _ selected: Int,
                          _ action: Selector, key: String) -> NSView {
        let p = NSPopUpButton()
        p.addItems(withTitles: items); p.selectItem(at: selected)
        p.autoenablesItems = false
        small(p); p.target = self; p.action = action
        p.setAccessibilityIdentifier(key); p.setAccessibilityLabel(title)
        return row(title, subtitle, trailing: p, key: key)
    }

    private func modelRow() -> NSView {
        modelPopup.removeAllItems()
        for m in prefsModels {
            let size = ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)
            modelPopup.addItem(withTitle: "\(m.title) · \(L10n.size(size))")
        }
        modelPopup.autoenablesItems = false
        small(modelPopup); modelPopup.target = self; modelPopup.action = #selector(modelChanged(_:))
        modelPopup.setAccessibilityIdentifier("ac.model")
        if let i = prefsModels.firstIndex(where: { $0.id == AutocompletePrefs.modelID }) { modelPopup.selectItem(at: i) }

        modelStatus.font = .systemFont(ofSize: 11); modelStatus.textColor = .secondaryLabelColor
        modelStatus.lineBreakMode = .byTruncatingTail
        modelStatus.setAccessibilityIdentifier("ac.modelStatus")
        progress.style = .bar; progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.controlSize = .small; progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 110).isActive = true
        for b in [downloadButton, deleteButton] { b.bezelStyle = .rounded; small(b); b.target = self }
        downloadButton.title = L10n.autocomplete("download"); downloadButton.action = #selector(downloadModel)
        deleteButton.title = L10n.autocomplete("delete"); deleteButton.action = #selector(deleteModel)
        downloadButton.setAccessibilityIdentifier("ac.download")
        deleteButton.setAccessibilityIdentifier("ac.deleteModel")

        let top = row(L10n.autocomplete("model"), nil, trailing: modelPopup)
        let controls = NSStackView(views: [modelStatus, progress, downloadButton, deleteButton])
        controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 8
        modelStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let bottom = NSStackView(views: [controls, spacer])
        bottom.orientation = .horizontal; bottom.alignment = .centerY
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 7, right: 11)
        let v = NSStackView(views: [top, bottom])
        v.orientation = .vertical; v.alignment = .width; v.spacing = 0
        return v
    }

    private func corpusRow() -> NSView {
        corpusCount.font = .systemFont(ofSize: 11); corpusCount.textColor = .secondaryLabelColor
        corpusCount.setAccessibilityIdentifier("ac.corpusCount")
        let del = button(L10n.autocomplete("deleteAll"), #selector(deleteCorpus))
        del.setAccessibilityIdentifier("ac.deleteCorpus")
        let box = NSStackView(views: [corpusCount, del])
        box.orientation = .horizontal; box.alignment = .centerY; box.spacing = 8
        return row(L10n.autocomplete("corpus"), L10n.autocomplete("corpusSub"), trailing: box)
    }

    private func aboutRow() -> NSView {
        let title = NSTextField(labelWithString: L10n.autocomplete("about"))
        title.font = .systemFont(ofSize: 12)
        let sub = WrappingLabel(string: L10n.autocomplete("aboutSub"))
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        aboutText.isRichText = false
        aboutText.font = .systemFont(ofSize: 12)
        aboutText.isVerticallyResizable = true; aboutText.isHorizontallyResizable = false
        aboutText.autoresizingMask = [.width]
        aboutText.textContainer?.widthTracksTextView = true
        aboutText.textContainerInset = NSSize(width: 3, height: 4)
        aboutText.string = AutocompletePrefs.globalInstruction
        aboutText.delegate = self
        aboutText.setAccessibilityIdentifier("ac.about")
        aboutText.setAccessibilityLabel(L10n.autocomplete("about"))
        scroll.documentView = aboutText
        let v = NSStackView(views: [title, sub, scroll])
        v.orientation = .vertical; v.alignment = .width; v.spacing = 3
        v.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 9, right: 11)
        return v
    }

    // MARK: - Приложения

    private func appName(_ bid: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bid
    }

    private func rebuildApps() {
        for v in appsBox.arrangedSubviews { appsBox.removeArrangedSubview(v); v.removeFromSuperview() }
        instructionFields.removeAll()
        let store = AutocompleteAppStore.shared
        let apps = store.configuredApps
        if apps.isEmpty {
            appsBox.addArrangedSubview(plainRow(L10n.autocomplete("appsEmpty"), trailing: nil))
        }
        for bid in apps {
            let excluded = AutocompleteAppStore.hardExcluded.contains(bid)
            let sw = NSSwitch(); sw.controlSize = .small
            sw.state = (!excluded && store.isEnabled(bid)) ? .on : .off
            sw.isEnabled = !excluded
            sw.target = self; sw.action = #selector(toggleApp(_:))
            sw.identifier = NSUserInterfaceItemIdentifier(bid)
            let field = NSTextField(string: store.instruction(bid))
            field.placeholderString = L10n.autocomplete("appInstruction")
            field.font = .systemFont(ofSize: 11); field.controlSize = .small
            field.delegate = self
            field.identifier = NSUserInterfaceItemIdentifier(bid)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            field.isEnabled = !excluded
            instructionFields[field] = bid
            let ctl = NSStackView(views: [field, sw])
            ctl.orientation = .horizontal; ctl.alignment = .centerY; ctl.spacing = 8
            let r = row(appName(bid), excluded ? L10n.autocomplete("appAlwaysOff") : nil, trailing: ctl)
            r.alphaValue = excluded ? 0.5 : 1
            if appsBox.arrangedSubviews.count > 0 { appsBox.addArrangedSubview(hairline()) }
            appsBox.addArrangedSubview(r)
        }
        if !apps.isEmpty { appsBox.addArrangedSubview(hairline()) }
        let add = button(L10n.autocomplete("addApp"), #selector(addApp))
        add.setAccessibilityIdentifier("ac.addApp")
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let br = NSStackView(views: [add, spacer])
        br.orientation = .horizontal; br.alignment = .centerY
        br.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 11)
        appsBox.addArrangedSubview(br)
    }

    // MARK: - Обновление

    private var selectedModel: CompletionModel? {
        let i = modelPopup.indexOfSelectedItem
        return prefsModels.indices.contains(i) ? prefsModels[i] : nil
    }

    private func refreshModel() {
        guard let m = selectedModel else { return }
        let installed = CompletionModels.isInstalled(m)
        var text: String
        if downloading { text = L10n.autocomplete("downloading") }
        else if !installed { text = L10n.autocomplete("notInstalled") }
        else {
            switch CompletionEngine.shared.state {
            case .stopped: text = L10n.autocomplete("stIdle")
            case .starting: text = L10n.autocomplete("stStarting")
            case .ready: text = L10n.autocomplete("stReady")
            case .failed(let why): text = L10n.autocomplete("stFailed") + why
            }
        }
        modelStatus.stringValue = text
        modelStatus.toolTip = text
        downloadButton.isHidden = installed || downloading
        deleteButton.isHidden = !installed || downloading
        progress.isHidden = !downloading
    }

    private func refreshCorpus() {
        corpusCount.stringValue = String(format: L10n.autocomplete("corpusCount"), PersonalCorpus.shared.count)
    }

    // MARK: - Действия

    @objc private func toggleEnabled(_ s: NSSwitch) {
        let on = s.state == .on
        AutocompletePrefs.enabled = on
        AutocompleteController.shared.setEnabled(on)
    }
    @objc private func modelChanged(_ p: NSPopUpButton) {
        guard let m = selectedModel else { return }
        AutocompletePrefs.modelID = m.id
        refreshModel()
        if AutocompletePrefs.enabled { AutocompleteController.shared.setEnabled(true) }
    }
    @objc private func downloadModel() {
        guard let m = selectedModel, !downloading else { return }
        downloading = true
        progress.doubleValue = 0
        refreshModel()
        CompletionModels.download(m, progress: { [weak self] p in
            DispatchQueue.main.async { self?.progress.doubleValue = p }
        }, done: { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloading = false
                self.refreshModel()
                if ok, AutocompletePrefs.enabled, AutocompletePrefs.modelID == m.id {
                    AutocompleteController.shared.setEnabled(true)
                }
                if !ok { self.modelStatus.stringValue = L10n.autocomplete("downloadFailed") }
            }
        })
    }
    @objc private func deleteModel() {
        guard let m = selectedModel else { return }
        if AutocompletePrefs.modelID == m.id { CompletionEngine.shared.stop() }
        CompletionModels.delete(m)
        refreshModel()
    }
    @objc private func wordsChanged(_ p: NSPopUpButton) { AutocompletePrefs.maxWords = wordsOptions[p.indexOfSelectedItem] }
    @objc private func pauseChanged(_ p: NSPopUpButton) { AutocompletePrefs.pauseMs = pauseOptions[p.indexOfSelectedItem] }
    @objc private func acceptAllChanged(_ p: NSPopUpButton) { AutocompletePrefs.acceptAllKeyCode = acceptAllOptions[p.indexOfSelectedItem] }
    @objc private func toggleTypo(_ s: NSSwitch) { AutocompletePrefs.typoFix = s.state == .on }
    @objc private func toggleBattery(_ s: NSSwitch) { AutocompletePrefs.batteryLight = s.state == .on }
    @objc private func recordChanged(_ p: NSPopUpButton) { AutocompletePrefs.recordMode = recordOptions[p.indexOfSelectedItem] }
    @objc private func strengthChanged(_ p: NSPopUpButton) { AutocompletePrefs.personalStrength = p.indexOfSelectedItem }
    @objc private func toggleClipboard(_ s: NSSwitch) { AutocompletePrefs.useClipboard = s.state == .on }
    @objc private func toggleDictation(_ s: NSSwitch) { AutocompletePrefs.dictationContext = s.state == .on }
    @objc private func toggleScreen(_ s: NSSwitch) {
        let on = s.state == .on
        AutocompletePrefs.useScreen = on
        if on, !ScreenContextProvider.hasPermission { ScreenContextProvider.requestPermission() }
    }
    @objc private func toggleApp(_ s: NSSwitch) {
        AutocompleteAppStore.shared.setEnabled(s.identifier?.rawValue ?? "", s.state == .on)
    }
    @objc private func deleteCorpus() {
        let alert = NSAlert()
        alert.messageText = L10n.autocomplete("deleteAllTitle")
        alert.informativeText = L10n.autocomplete("deleteAllText")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.autocomplete("deleteAllOk"))
        alert.addButton(withTitle: L10n.autocomplete("cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PersonalCorpus.shared.removeAll()
        refreshCorpus()
    }
    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.autocomplete("addAppMessage")
        guard panel.runModal() == .OK, let url = panel.url,
              let bid = Bundle(url: url)?.bundleIdentifier else { return }
        let store = AutocompleteAppStore.shared
        store.setEnabled(bid, store.isEnabled(bid))   // заносит приложение в список настроенных
        rebuildApps()
    }
    @objc private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Делегаты полей

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === aboutText else { return }
        AutocompletePrefs.globalInstruction = aboutText.string
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let bid = instructionFields[f] else { return }
        AutocompleteAppStore.shared.setInstruction(bid, f.stringValue)
    }
}
