import AppKit
import UniformTypeIdentifiers

private final class JournalButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, id: String = "", action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(invoke)
        setAccessibilityIdentifier(id); perform = action
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func invoke() { perform?() }
}

final class LayoutJournalView: NSStackView, NSTextFieldDelegate {
    private let runtime: LayoutDiagnosticsRuntime
    private let presenter = LayoutJournalPresenter()
    private var observer: NSObjectProtocol?
    private var snapshot = LayoutJournalSnapshot(cases: [], rules: [], prunedCount: 0, loadError: nil)
    private var selectedID: UUID?
    private var page = 1
    private var busy = false
    private var pendingRefresh = false
    private var operationFailed = false
    private var addButton: NSButton?
    private let body = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let reviewNotice = NSTextField(wrappingLabelWithString: "")
    private let collection = NSSwitch()
    private let kind = NSPopUpButton()
    private let app = NSPopUpButton()
    private let status = NSPopUpButton()
    private let sort = NSPopUpButton()
    private let stream = NSSegmentedControl()
    private let decisionAction = NSPopUpButton()
    private let decisionReason = NSPopUpButton()
    private let dictionary = NSPopUpButton()
    private let caseFilters = NSStackView()
    private let decisionFilters = NSStackView()
    private var appIDs: [String] = []
    private var expectedField: NSTextField?
    private var ruleButtons: [(NSButton, LayoutRuleAction, LayoutCase)] = []

    init(runtime: LayoutDiagnosticsRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        let title = text(L10n.t("sec.layoutJournal"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        addArrangedSubview(title)
        collection.state = runtime.enabled ? .on : .off
        collection.target = self; collection.action = #selector(toggleCollection)
        collection.setAccessibilityIdentifier("journal.collection")
        addArrangedSubview(card([row([label("collection"), collection]), label("privacy", secondary: true)]))
        let add = button("add", id: "journal.add") { [weak self] in self?.showForm() }
        add.isEnabled = runtime.enabled; addButton = add
        let tools = row([add,
                         button("export") { [weak self] in self?.export(false) },
                         button("exportConfirmed") { [weak self] in self?.export(true) },
                         button("clear", id: "journal.clear") { [weak self] in self?.clear() }])
        addArrangedSubview(tools)
        for (popup, titles, id) in [(kind, ["allKinds","missedConversion","unwantedConversion"], "kind"),
                                     (status, ["allStatuses","candidate","confirmed","rejected","resolved"], "status"),
                                     (sort, ["repeats","recent"], "sort")] {
            popup.addItems(withTitles: titles.map(L10n.journal)); configure(popup, id: id)
        }
        app.addItem(withTitle: L10n.journal("allApps")); configure(app, id: "app")
        app.widthAnchor.constraint(lessThanOrEqualToConstant: 150).isActive = true
        stream.segmentCount = 2
        stream.setLabel(L10n.journal("decisions"), forSegment: 0)
        stream.setLabel(L10n.journal("errors"), forSegment: 1)
        stream.selectedSegment = 0; stream.target = self; stream.action = #selector(filterChanged)
        stream.setAccessibilityIdentifier("journal.stream")
        addArrangedSubview(row([stream, app]))
        caseFilters.orientation = .vertical; caseFilters.alignment = .leading; caseFilters.spacing = 8
        caseFilters.addArrangedSubview(kind); caseFilters.addArrangedSubview(row([status, sort]))
        addArrangedSubview(caseFilters)
        decisionAction.addItems(withTitles: [L10n.journal("allActions")] + LayoutAction.allCases.map { L10n.journal("action." + $0.rawValue) })
        decisionReason.addItems(withTitles: [L10n.journal("allReasons")] + LayoutReason.allCases.map { L10n.journal("reason." + $0.rawValue) })
        dictionary.addItems(withTitles: [L10n.journal("allDictionary")] + LayoutDictionaryMatch.allCases.map { L10n.journal("dictionary." + $0.rawValue) })
        for (popup, id) in [(decisionAction, "action"), (decisionReason, "reason"), (dictionary, "dictionary")] { configure(popup, id: id) }
        decisionFilters.orientation = .vertical; decisionFilters.alignment = .leading; decisionFilters.spacing = 8
        decisionFilters.addArrangedSubview(row([decisionAction, decisionReason]))
        decisionFilters.addArrangedSubview(dictionary)
        addArrangedSubview(decisionFilters)
        kind.widthAnchor.constraint(equalToConstant: 200).isActive = true
        status.widthAnchor.constraint(equalToConstant: 200).isActive = true
        sort.widthAnchor.constraint(equalToConstant: 180).isActive = true
        message.textColor = .secondaryLabelColor; message.font = .systemFont(ofSize: 12)
        addArrangedSubview(message)
        reviewNotice.font = .systemFont(ofSize: 12, weight: .medium)
        reviewNotice.setAccessibilityIdentifier("journal.reviewNotice")
        reviewNotice.isHidden = true
        addArrangedSubview(reviewNotice)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 8
        addArrangedSubview(body)
        for view in [body, message, reviewNotice] { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .layoutDiagnosticsChanged, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
            refresh()
        } else if window == nil {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil; runtime.journalEditing = false
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func controlTextDidBeginEditing(_ obj: Notification) { runtime.journalEditing = true }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === expectedField else { return }
        for (button, action, item) in ruleButtons {
            button.isEnabled = !busy && field.stringValue == item.expected && runtime.canApply(item, action: action)
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        runtime.journalEditing = false
        if pendingRefresh { pendingRefresh = false; refresh() }
    }
    private func configure(_ popup: NSPopUpButton, id: String) {
        popup.target = self; popup.action = #selector(filterChanged); popup.setAccessibilityIdentifier("journal.filter." + id)
    }
    @objc private func toggleCollection() { runtime.setEnabled(collection.state == .on); refresh() }
    @objc private func filterChanged() { page = 1; render() }
    func whenReady(_ completion: @escaping () -> Void) { refresh(completion: completion) }

    private func refresh(completion: (() -> Void)? = nil) {
        guard window != nil else { return }
        guard !runtime.journalEditing else { pendingRefresh = true; return }
        runtime.store.snapshot { [weak self] snapshot in
            guard let self, self.window != nil else { return }
            guard !self.runtime.journalEditing else { self.pendingRefresh = true; return }
            self.snapshot = snapshot
            let selectedApp = self.app.indexOfSelectedItem > 0 ? self.appIDs[self.app.indexOfSelectedItem - 1] : nil
            self.appIDs = Array(Set(snapshot.cases.map(\.bundleID) + snapshot.observations.map(\.bundleID))).sorted()
            self.app.removeAllItems(); self.app.addItem(withTitle: L10n.journal("allApps")); self.app.addItems(withTitles: self.appIDs.map(self.appName))
            if let selectedApp, let index = self.appIDs.firstIndex(of: selectedApp) { self.app.selectItem(at: index + 1) }
            self.collection.state = self.runtime.enabled ? .on : .off
            self.addButton?.isEnabled = self.runtime.enabled && !self.busy
            if self.operationFailed || snapshot.loadError != nil || self.runtime.lastError != nil { self.showError() }
            else { self.message.textColor = .secondaryLabelColor; self.message.stringValue = "\(snapshot.cases.count) " + L10n.journal("cases") + " · \(snapshot.observations.count) " + L10n.journal("decisionsCount") + " · \(snapshot.prunedCount) " + L10n.journal("pruned") }
            self.render()
            DispatchQueue.main.async { completion?() }
        }
    }
    private func render() {
        guard !runtime.journalEditing else { pendingRefresh = true; return }
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        expectedField = nil; ruleButtons.removeAll()
        let decisions = stream.selectedSegment == 0
        caseFilters.isHidden = decisions; decisionFilters.isHidden = !decisions
        if decisions { renderDecisions() }
        else {
            let filter = LayoutJournalPresenter.Filter(kind: kind.indexOfSelectedItem == 0 ? nil : (kind.indexOfSelectedItem == 1 ? .missedConversion : .unwantedConversion), bundleID: app.indexOfSelectedItem > 0 ? appIDs[app.indexOfSelectedItem - 1] : nil, status: [nil, .candidate, .confirmed, .rejected, .resolved][status.indexOfSelectedItem])
            let cases = presenter.rows(cases: snapshot.cases, filter: filter, sort: sort.indexOfSelectedItem == 0 ? .repeats : .recent)
            if cases.isEmpty { body.addArrangedSubview(label("empty", secondary: true)) }
            for item in cases.prefix(page * 30) {
                let select = JournalButton("\(item.typed)  →  \(item.produced ?? "—")  →  \(item.expected)", id: "journal.case.\(item.id)") { [weak self] in
                    guard let self else { return }
                    self.window?.makeFirstResponder(nil)
                    self.selectedID = self.selectedID == item.id ? nil : item.id
                    self.render()
                }
                select.contentTintColor = NSColor(srgbRed: 1, green: 122/255, blue: 89/255, alpha: 1)
                let reviewStatus = label(item.status.rawValue)
                reviewStatus.setAccessibilityIdentifier("journal.case.status.\(item.id)")
                if item.status == .confirmed { reviewStatus.textColor = .systemGreen }
                else if item.status == .rejected { reviewStatus.textColor = .systemRed }
                var views: [NSView] = [label("columns", secondary: true), select, text("\(appName(item.bundleID)) · \(item.count) × · \(L10n.journal(item.kind.rawValue))", secondary: true), reviewStatus]
                if selectedID == item.id { views += detail(item) }
                body.addArrangedSubview(card(views))
            }
            if cases.count > page * 30 { body.addArrangedSubview(button("more") { [weak self] in self?.page += 1; self?.render() }) }
        }
        let rules = snapshot.rules.filter { $0.status != .removed }
        if !rules.isEmpty {
            body.addArrangedSubview(DetailVC.eyebrowLabel(L10n.journal("rules")))
            body.addArrangedSubview(label("global", secondary: true))
            for rule in rules {
                let remove = button(rule.status == .conflict ? "retryRemove" : "remove", id: "journal.remove") { [weak self] in self?.operate { done in self?.runtime.rules.remove(id: rule.id, completion: done) } }
                remove.isEnabled = runtime.rulesReady && !busy && rule.status != .pending
                var views: [NSView] = [text("\(rule.typed) → \(rule.expected) · \(L10n.journal(rule.status.rawValue))"), remove]
                if rule.status == .conflict { views += [label("conflictHelp", secondary: true), button("forget") { [weak self] in self?.operate { done in self?.runtime.rules.forgetConflict(id: rule.id, completion: done) } }] }
                body.addArrangedSubview(card(views))
            }
        }
    }
    private func renderDecisions() {
        let filter = LayoutJournalPresenter.ObservationFilter(
            bundleID: app.indexOfSelectedItem > 0 ? appIDs[app.indexOfSelectedItem - 1] : nil,
            action: decisionAction.indexOfSelectedItem > 0 ? LayoutAction.allCases[decisionAction.indexOfSelectedItem - 1] : nil,
            reason: decisionReason.indexOfSelectedItem > 0 ? LayoutReason.allCases[decisionReason.indexOfSelectedItem - 1] : nil,
            dictionaryMatch: dictionary.indexOfSelectedItem > 0 ? LayoutDictionaryMatch.allCases[dictionary.indexOfSelectedItem - 1] : nil)
        let observations = presenter.observations(snapshot.observations, filter: filter)
        body.addArrangedSubview(label("decisionsHelp", secondary: true))
        if observations.isEmpty { body.addArrangedSubview(label("emptyDecisions", secondary: true)) }
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 3 * 3600)
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss 'MSK'"
        for item in observations.prefix(page * 30) {
            let select = JournalButton(item.typed + " · " + L10n.journal("action." + item.action.rawValue), id: "journal.observation.\(item.id)") { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(nil)
                self.selectedID = self.selectedID == item.id ? nil : item.id
                self.render()
            }
            var views: [NSView] = [select,
                text(appName(item.bundleID) + " · " + formatter.string(from: item.recordedAt), secondary: true),
                text(L10n.journal("reason." + item.reason.rawValue) + " · " + L10n.journal("path." + item.path.rawValue), secondary: true),
                text(L10n.journal("alternative") + ": " + (item.alternative ?? "—") + " · " + L10n.journal("dictionary." + (item.dictionaryMatch ?? .unavailable).rawValue), secondary: true),
                text(L10n.journal("produced") + ": " + (item.proposed ?? "—") + " · " + L10n.journal("submission." + item.submission.rawValue), secondary: true)]
            views += neuralViews(item)
            if selectedID == item.id {
                let linked = snapshot.markedObservationIDs.contains(item.id)
                if linked { views.append(label("alreadyMarked", secondary: true)) }
                else {
                    views.append(HairlineView())
                    views.append(label("suggestedExpected", secondary: true))
                    let field = input(item.action == .replace ? item.typed : (item.alternative ?? ""), placeholder: "expected", id: "journal.observation.expected")
                    expectedField = field; field.isEnabled = runtime.enabled && !busy
                    views.append(field)
                    let mark = button("markDecision", id: "journal.observation.mark") { [weak self, weak field] in
                        guard let self, let field else { return }
                        let expected = field.stringValue
                        guard !expected.isEmpty, expected.count <= 128, !expected.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                            self.showError(); return
                        }
                        self.window?.makeFirstResponder(nil)
                        self.runtime.controller.mark(observation: item, expected: expected,
                            kind: item.action == .replace ? .unwantedConversion : .missedConversion)
                    }
                    mark.isEnabled = runtime.enabled && !busy
                    views.append(mark)
                }
                if !item.isCompleteWord { views.append(label("incomplete", secondary: true)) }
                if item.action == .blocked { views.append(label("protected", secondary: true)) }
            }
            body.addArrangedSubview(card(views))
        }
        if observations.count > page * 30 { body.addArrangedSubview(button("more") { [weak self] in self?.page += 1; self?.render() }) }
    }

    private func neuralViews(_ observation: LayoutObservation) -> [NSView] {
        guard let details = presenter.neuralDetails(for: observation) else { return [] }
        let proposal = details.proposal.rawValue
        let proposed = text(L10n.neural("proposal") + ": " + L10n.neural(proposal))
        proposed.setAccessibilityIdentifier("journal.neural.proposal")
        let actual = text(L10n.neural("actual") + ": " + L10n.journal("action." + details.action.rawValue) + " · " + L10n.journal("submission." + details.submission.rawValue))
        actual.setAccessibilityIdentifier("journal.neural.actual")
        let reason = text(L10n.neural("reason") + ": " + L10n.journal("reason." + details.reason.rawValue) + " · " + (details.block.map { L10n.neural("block." + $0.rawValue) } ?? L10n.neural(details.mode.rawValue)), secondary: true)
        reason.setAccessibilityIdentifier("journal.neural.reason")
        return [proposed, actual, reason,
            text(L10n.neural("score") + ": " + (details.score.map { String(format: "%.3f", $0) } ?? "—"), secondary: true),
            text(L10n.neural("scoreHelp"), secondary: true)]
    }

    private func detail(_ item: LayoutCase) -> [NSView] {
        let locked = snapshot.rules.contains { $0.sourceCaseID == item.id && $0.status != .removed }
        let field = input(item.expected, placeholder: "expected", id: "journal.expected"); expectedField = field
        field.isEnabled = !locked && !busy
        let confirm = button("confirm", id: "journal.confirm") { [weak self, weak field] in self?.review(item, expected: field?.stringValue ?? item.expected, status: .confirmed) }
        confirm.bezelColor = .systemGreen; confirm.contentTintColor = .white
        confirm.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        let reject = button("reject", id: "journal.reject") { [weak self] in self?.review(item, expected: item.expected, status: .rejected) }
        reject.bezelColor = .systemRed; reject.contentTintColor = .white
        reject.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        confirm.isEnabled = !locked && !busy; reject.isEnabled = !locked && !busy
        var result: [NSView] = [HairlineView(), label("expected"), field, row([confirm, reject])]
        if item.status == .confirmed || item.status == .rejected {
            let saved = label(item.status == .confirmed ? "confirmSaved" : "rejectSaved")
            saved.textColor = item.status == .confirmed ? .systemGreen : .systemRed
            result.append(saved)
        }
        if locked { result.append(label("locked", secondary: true)) }
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 3 * 3600); formatter.dateFormat = "dd.MM.yyyy HH:mm:ss 'MSK'"
        for evidence in item.evidence.suffix(5) {
            let o = evidence.observation
            result += neuralViews(o)
            result.append(text("\(formatter.string(from: evidence.createdAt)) · \(L10n.journal("source")): \(evidence.source.rawValue)\n\(L10n.journal("decision")): \(o.reason.rawValue) · \(o.path.rawValue) · \(o.submission.rawValue)", secondary: true))
        }
        result.append(text(formatter.string(from: item.firstSeen) + " — " + formatter.string(from: item.lastSeen), secondary: true))
        result += [label("global", secondary: true)]
        if !locked && !runtime.canApply(item, action: .keep) && !runtime.canApply(item, action: .force) {
            let hint: String
            if item.status != .confirmed { hint = "confirmFirst" }
            else if !item.isCompleteWord { hint = "incomplete" }
            else if !runtime.rulesReady { hint = "loadingRules" }
            else if item.evidence.last?.observation.action == .blocked { hint = "protected" }
            else { hint = "unsupported" }
            result.append(label(hint, secondary: true))
        }
        for (key, action) in [("keep", LayoutRuleAction.keep), ("force", .force)] {
            let apply = button(key, id: "journal.apply.\(key)") { [weak self] in
                guard let self, self.expectedField?.stringValue == item.expected else { return }
                self.operate { done in self.runtime.rules.apply(caseID: item.id, action: action) { done($0.map { _ in () }) } }
            }
            apply.isEnabled = !locked && !busy && runtime.canApply(item, action: action)
            ruleButtons.append((apply, action, item)); result.append(apply)
        }
        return result
    }
    private func review(_ item: LayoutCase, expected: String, status: LayoutReviewStatus) {
        window?.makeFirstResponder(nil)
        operate { done in
            runtime.store.review(caseID: item.id, expected: expected, status: status) { [weak self] result in
                if case .success = result, let self {
                    self.reviewNotice.stringValue = L10n.journal(status == .confirmed ? "confirmSaved" : "rejectSaved")
                    self.reviewNotice.textColor = status == .confirmed ? .systemGreen : .systemRed
                    self.reviewNotice.isHidden = false
                    NSAccessibility.post(element: self.reviewNotice, notification: .announcementRequested,
                        userInfo: [.announcement: self.reviewNotice.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
                done(result)
            }
        }
    }
    private func operate(_ operation: (@escaping LayoutJournalStore.Completion) -> Void) {
        guard !busy else { return }; busy = true; operationFailed = false; render()
        reviewNotice.isHidden = true
        operation { [weak self] result in
            guard let self else { return }; self.busy = false
            if case .failure = result { self.operationFailed = true; self.showError() }
            self.refresh()
        }
    }
    private func showError() { message.stringValue = L10n.journal("error") + " · \(snapshot.prunedCount) " + L10n.journal("pruned"); message.textColor = .systemRed }
    private func clear() {
        let alert = NSAlert(); alert.messageText = L10n.journal("clearQuestion"); alert.informativeText = L10n.journal("clearHelp")
        alert.addButton(withTitle: L10n.journal("clear")); alert.addButton(withTitle: L10n.journal("cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            operate { runtime.clearJournal(completion: $0) }
        }
    }
    private func export(_ confirmed: Bool) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "layout-journal.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operate { runtime.store.export(to: url, confirmedOnly: confirmed, completion: $0) }
    }
    private func showForm() {
        guard runtime.enabled else { message.stringValue = L10n.journal("enableFirst"); return }
        let panel = NSAlert(); panel.messageText = L10n.journal("add")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        let recent = NSPopUpButton(); recent.addItem(withTitle: L10n.journal("manual"))
        let frozen = runtime.frozenRecent
        recent.addItems(withTitles: frozen.map { "\(appName($0.bundleID)): \($0.typed) → \($0.proposed ?? "—")" })
        let typed = input("", placeholder: "typed", id: "journal.manual.typed")
        let expected = input("", placeholder: "expected", id: "journal.manual.expected")
        let application = NSPopUpButton()
        application.setAccessibilityIdentifier("journal.manual.app")
        var applications = NSWorkspace.shared.runningApplications.compactMap { app -> (String, String)? in
            guard let id = app.bundleIdentifier, id != runtime.ownBundleID, let name = app.localizedName,
                  app.activationPolicy == .regular else { return nil }
            return (name, id)
        }.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        application.addItem(withTitle: L10n.journal("chooseApp"))
        application.addItems(withTitles: applications.map { $0.0 })
        let choose = button("otherApp") {
            let picker = NSOpenPanel(); picker.allowedContentTypes = [.applicationBundle]
            picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
            guard picker.runModal() == .OK, let url = picker.url, let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier else { return }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? url.deletingPathExtension().lastPathComponent
            applications.append((name, id)); application.addItem(withTitle: name)
            application.selectItem(at: applications.count)
        }
        let kind = NSPopUpButton(); kind.addItems(withTitles: ["missedConversion", "unwantedConversion"].map(L10n.journal))
        for view in [label("recentHelp", secondary: true), recent, typed, expected, row([application, choose]), kind] { stack.addArrangedSubview(view) }
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        panel.accessoryView = stack; panel.addButton(withTitle: L10n.journal("save")); panel.addButton(withTitle: L10n.journal("cancel"))
        let answer = panel.runModal(); runtime.journalEditing = false
        guard answer == .alertFirstButtonReturn else { return }
        let errorKind: LayoutErrorKind = kind.indexOfSelectedItem == 0 ? .missedConversion : .unwantedConversion
        guard runtime.enabled, Self.valid(expected.stringValue) else { showError(); return }
        if recent.indexOfSelectedItem > 0 {
            let selected = frozen[recent.indexOfSelectedItem - 1]
            guard runtime.frozenRecent.contains(where: { $0.id == selected.id }) else { message.stringValue = L10n.journal("expired"); return }
            runtime.controller.mark(observation: selected, expected: expected.stringValue, kind: errorKind)
        } else {
            guard Self.valid(typed.stringValue), application.indexOfSelectedItem > 0 else { showError(); return }
            runtime.controller.addManualCase(typed: typed.stringValue, expected: expected.stringValue, bundleID: applications[application.indexOfSelectedItem - 1].1, kind: errorKind)
        }
    }
    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) else { return bundleID }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
    private static func valid(_ value: String) -> Bool { !value.isEmpty && value.count <= 128 && !value.contains(where: { $0.isWhitespace }) }
    private func input(_ value: String, placeholder: String, id: String) -> NSTextField {
        let field = NSTextField(string: value); field.placeholderString = L10n.journal(placeholder); field.delegate = self
        field.setAccessibilityIdentifier(id); field.widthAnchor.constraint(equalToConstant: 380).isActive = true; return field
    }
    private func button(_ key: String, id: String = "", action: @escaping () -> Void) -> NSButton { JournalButton(L10n.journal(key), id: id, action: action) }
    private func label(_ key: String, secondary: Bool = false) -> NSTextField { text(L10n.journal(key), secondary: secondary) }
    private func text(_ value: String, secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value); label.font = .systemFont(ofSize: secondary ? 11 : 12)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor; return label
    }
    private func row(_ views: [NSView]) -> NSStackView {
        for case let control as NSControl in views {
            control.controlSize = .small
            control.font = .systemFont(ofSize: 12)
        }
        let stack = NSStackView(views: views); stack.spacing = 8
        return stack
    }
    private func card(_ views: [NSView]) -> NSView {
        let card = CardView(); card.wantsLayer = true; card.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
        NSLayoutConstraint.activate([card.widthAnchor.constraint(equalToConstant: DS.contentWidth), stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 11), stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -11), stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 9), stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9)])
        return card
    }
}
