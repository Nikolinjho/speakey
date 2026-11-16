import AppKit

/// Раздел настроек «Автодополнение». Отдельный NSStackView по образцу NeuralLayoutSettingsView:
/// строки и карточки повторяют оформление SettingsWindow (CardView, hairline, 12/11 pt).
final class AutocompleteSettingsView: NSStackView, NSTextViewDelegate {
    private let prefsModels = CompletionModels.all
    private let wordsOptions = [3, 6, 10]
    private let pauseOptions = [80, 120, 200, 350]
    private let escapeOptions = CompletionEscapeMode.allCases
    private var shortcutButtons: [CompletionAction: NSButton] = [:]
    private let recordOptions: [AutocompleteRecordMode] = [.off, .accepted, .all]

    private let modelPopup = NSPopUpButton()
    private let modelStatus = NSTextField(labelWithString: "")
    private let downloadButton = NSButton()
    private let deleteButton = NSButton()
    private let progress = NSProgressIndicator()
    private var downloading = false
    private let corpusCount = NSTextField(labelWithString: "")
    private let aboutText = NSTextView()
    private var timer: Timer?
    private let appStore: AutocompleteAppStore
    private let corpus: PersonalCorpus
    private var corpusWindow: PersonalCorpusWindowController?
    private var corpusRefreshPending = false

    init(appStore: AutocompleteAppStore = .shared, corpus: PersonalCorpus = .shared) {
        self.appStore = appStore; self.corpus = corpus
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = DS.itemGap
        build()
        for item in arrangedSubviews {
            item.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
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
        addArrangedSubview(leftAligned(title))
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
            switchRow(L10n.autocomplete("trailingSpace"), nil,
                      AutocompletePrefs.trailingSpace, #selector(toggleTrailingSpace(_:)), key: "ac.trailingSpace"),
            switchRow(L10n.autocomplete("trailingPunctuation"), nil,
                      AutocompletePrefs.trailingPunctuation, #selector(toggleTrailingPunctuation(_:)), key: "ac.trailingPunctuation"),
            switchRow(L10n.autocomplete("tabEnabled"), L10n.autocomplete("tabEnabledSub"),
                      AutocompletePrefs.tabEnabled, #selector(toggleTab(_:)), key: "ac.tabEnabled"),
            popupRow(L10n.autocomplete("escapeMode"), nil,
                     escapeOptions.map { L10n.autocomplete("escape.\($0.rawValue)") },
                     escapeOptions.firstIndex(of: AutocompletePrefs.escapeMode) ?? 0,
                     #selector(escapeChanged(_:)), key: "ac.escapeMode"),
            switchRow(L10n.autocomplete("typo"), L10n.autocomplete("typoSub"),
                      AutocompletePrefs.typoFix, #selector(toggleTypo(_:)), key: "ac.typo"),
            switchRow(L10n.autocomplete("battery"), L10n.autocomplete("batterySub"),
                      AutocompletePrefs.batteryLight, #selector(toggleBattery(_:)), key: "ac.battery")
        ]))

        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("editingTitle")))
        addArrangedSubview(card([
            switchRow(L10n.autocomplete("onlyCurrentWord"), L10n.autocomplete("onlyCurrentWordSub"),
                      AutocompletePrefs.onlyCurrentWord, #selector(toggleOnlyWord(_:)), key: "ac.onlyCurrentWord"),
            switchRow(L10n.autocomplete("inlineCompletion"), L10n.autocomplete("inlineCompletionSub"),
                      AutocompletePrefs.inlineCompletion, #selector(toggleInline(_:)), key: "ac.inlineCompletion"),
            switchRow(L10n.autocomplete("autoAlternatives"), L10n.autocomplete("autoAlternativesSub"),
                      AutocompletePrefs.autoAlternatives, #selector(toggleAlternatives(_:)), key: "ac.autoAlternatives"),
            switchRow(L10n.autocomplete("autoSynonyms"), L10n.autocomplete("autoSynonymsSub"),
                      AutocompletePrefs.autoSynonyms, #selector(toggleSynonyms(_:)), key: "ac.autoSynonyms"),
            popupRow(L10n.autocomplete("variantsDelay"), nil, [300, 600, 1000, 1500].map { String(format: L10n.autocomplete("ms"), $0) },
                     [300, 600, 1000, 1500].firstIndex(of: AutocompletePrefs.variantsDelayMs) ?? 1,
                     #selector(variantsDelayChanged(_:)), key: "ac.variantsDelay")
        ]))
        addArrangedSubview(gap(6))
        addArrangedSubview(eyebrow(L10n.autocomplete("shortcutsTitle")))
        addArrangedSubview(card(CompletionAction.allCases.map { shortcutRow($0) }))
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
        addArrangedSubview(AutocompleteAppsView(store: appStore, corpus: corpus) { [weak self] bid in self?.showCorpus(bundleID: bid) })
        addArrangedSubview(note(L10n.autocomplete("appRecordGate")))
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

    private func eyebrow(_ t: String) -> NSView { leftAligned(DetailVC.eyebrowLabel(t)) }

    /// В вертикальном стеке с `.width` лейбл растягивался и рисовался у правого края. Ряд с
    /// распоркой держит его слева, как заголовки в остальных разделах.
    private func leftAligned(_ v: NSView) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [v, spacer])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 0
        return row
    }

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
        // Как в DetailVC.settingRow: переносимая подпись не должна съедать поля строки.
        r.heightAnchor.constraint(greaterThanOrEqualTo: col.heightAnchor, constant: 10).isActive = true
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
        r.heightAnchor.constraint(greaterThanOrEqualTo: s.heightAnchor, constant: 14).isActive = true
        if let trailing {
            r.heightAnchor.constraint(greaterThanOrEqualTo: trailing.heightAnchor, constant: 14).isActive = true
        }
        r.setClippingResistancePriority(.required, for: .vertical)
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
        bottom.heightAnchor.constraint(greaterThanOrEqualTo: controls.heightAnchor, constant: 7).isActive = true
        let v = NSStackView(views: [top, bottom])
        v.orientation = .vertical; v.alignment = .width; v.spacing = 0
        return v
    }

    private func corpusRow() -> NSView {
        corpusCount.font = .systemFont(ofSize: 11); corpusCount.textColor = .secondaryLabelColor
        corpusCount.setAccessibilityIdentifier("ac.corpusCount")
        let browse = button(L10n.autocomplete("corpusBrowse"), #selector(browseCorpus))
        browse.setAccessibilityIdentifier("ac.browseCorpus")
        let box = NSStackView(views: [corpusCount, browse])
        box.orientation = .horizontal; box.alignment = .centerY; box.spacing = DS.itemGap
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
        let v = NSStackView(views: [leftAligned(title), sub, scroll])
        v.orientation = .vertical; v.alignment = .width; v.spacing = 3
        v.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 9, right: 11)
        v.setClippingResistancePriority(.required, for: .vertical)
        return v
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
        guard !corpusRefreshPending else { return }
        corpusRefreshPending = true
        PersonalCorpus.workQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.corpus.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.corpusRefreshPending = false
                self.corpusCount.stringValue = snapshot.available
                    ? String(format: L10n.autocomplete("corpusCount"), snapshot.records.count)
                    : L10n.autocomplete("corpusUnavailableShort")
            }
        }
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
    @objc private func toggleOnlyWord(_ s: NSSwitch) { AutocompletePrefs.onlyCurrentWord = s.state == .on }
    @objc private func toggleInline(_ s: NSSwitch) { AutocompletePrefs.inlineCompletion = s.state == .on }
    @objc private func toggleAlternatives(_ s: NSSwitch) { AutocompletePrefs.autoAlternatives = s.state == .on }
    @objc private func toggleSynonyms(_ s: NSSwitch) { AutocompletePrefs.autoSynonyms = s.state == .on }
    @objc private func variantsDelayChanged(_ p: NSPopUpButton) { AutocompletePrefs.variantsDelayMs = [300, 600, 1000, 1500][p.indexOfSelectedItem] }
    @objc private func toggleTrailingSpace(_ s: NSSwitch) { AutocompletePrefs.trailingSpace = s.state == .on }
    @objc private func toggleTrailingPunctuation(_ s: NSSwitch) { AutocompletePrefs.trailingPunctuation = s.state == .on }
    @objc private func toggleTab(_ s: NSSwitch) { AutocompletePrefs.tabEnabled = s.state == .on }
    @objc private func escapeChanged(_ p: NSPopUpButton) { AutocompletePrefs.escapeMode = escapeOptions[p.indexOfSelectedItem] }

    private func shortcutRow(_ action: CompletionAction) -> NSView {
        let record = button(AutocompleteShortcutRecorder.label(AutocompletePrefs.shortcut(action)), #selector(recordShortcut(_:)))
        record.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        record.setAccessibilityIdentifier("ac.shortcut.\(action.rawValue)")
        record.setAccessibilityLabel(L10n.autocomplete("action.\(action.rawValue)"))
        shortcutButtons[action] = record
        let clear = button(L10n.autocomplete("clearShortcut"), #selector(clearShortcut(_:)))
        clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        clear.setAccessibilityIdentifier("ac.clearShortcut.\(action.rawValue)")
        let controls = NSStackView(views: [record, clear])
        controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = DS.itemGap
        return row(L10n.autocomplete("action.\(action.rawValue)"), nil, trailing: controls)
    }
    @objc private func recordShortcut(_ button: NSButton) {
        guard let id = button.identifier?.rawValue, let action = CompletionAction(rawValue: id) else { return }
        AutocompleteShortcutRecorder.shared.start(action, window: window) { [weak self] in
            self?.shortcutButtons[action]?.title = AutocompleteShortcutRecorder.label(AutocompletePrefs.shortcut(action))
        }
    }
    @objc private func clearShortcut(_ button: NSButton) {
        guard let id = button.identifier?.rawValue, let action = CompletionAction(rawValue: id) else { return }
        AutocompletePrefs.setShortcut(nil, for: action)
        shortcutButtons[action]?.title = AutocompleteShortcutRecorder.label(nil)
    }
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
    @objc private func browseCorpus() { showCorpus(bundleID: nil) }
    private func showCorpus(bundleID: String?) {
        if corpusWindow == nil { corpusWindow = PersonalCorpusWindowController(corpus: corpus) }
        corpusWindow?.show(bundleID: bundleID)
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
}
