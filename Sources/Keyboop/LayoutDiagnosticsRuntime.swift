import Foundation

extension Notification.Name {
    static let layoutDiagnosticsChanged = Notification.Name("layoutDiagnosticsChanged")
}

final class LayoutDiagnosticsRuntime {
    private static var override: LayoutDiagnosticsRuntime?
    private static let live = LayoutDiagnosticsRuntime()
    static var shared: LayoutDiagnosticsRuntime {
        get { override ?? live }
        set { override = newValue }
    }
    let store: LayoutJournalStore
    let rules: LayoutRuleService
    let controller: LayoutDiagnosticsController
    private(set) var rulesReady = false
    private(set) var lastError: Error?
    private var changeScheduled = false
    var journalEditing = false {
        didSet { if journalEditing != oldValue { controller.resetContext() } }
    }
    let ownBundleID: String

    private let settings: AppSettings
    private let backend: LayoutRuleBackend

    init(store injectedStore: LayoutJournalStore? = nil, settings: AppSettings = .shared, backend: LayoutRuleBackend = ExceptionLayoutRuleBackend()) {
        self.settings = settings
        self.backend = backend
        ownBundleID = Bundle.main.bundleIdentifier ?? "com.keyboop.app"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = injectedStore ?? LayoutJournalStore(directory: support.appendingPathComponent(ownBundleID).appendingPathComponent("LayoutDiagnostics"))
        self.store = store
        rules = LayoutRuleService(store: store, backend: backend)
        var recorded: ((Result<Void, Error>) -> Void)?
        controller = LayoutDiagnosticsController(enabled: settings.layoutDiagnosticsEnabled, sink: { feedback in
            store.record(feedback) { result in recorded?(result) }
        })
        recorded = { [weak self] result in self?.finished(result) }
        controller.onObservation = { observation in
            store.recordObservation(observation) { result in recorded?(result) }
        }
        controller.onSubmission = { id, submitted in
            store.updateSubmission(observationID: id, submitted: submitted) { result in recorded?(result) }
        }
        controller.onChange = { [weak self] in self?.notifyChange() }
        store.snapshot { [weak self] snapshot in
            if let error = snapshot.loadError { self?.lastError = error; self?.notifyChange() }
        }
        rules.reconcilePending { [weak self] result in
            guard let self else { return }
            if case .success = result { self.rulesReady = true }
            self.finished(result)
        }
    }

    func canApply(_ item: LayoutCase, action: LayoutRuleAction) -> Bool {
        rulesReady && (try? LayoutRuleService.prepare(case: item, action: action, backend: backend)) != nil
    }

    var enabled: Bool { controller.enabled }
    var recent: [LayoutObservation] { controller.recent }
    var frozenRecent: [LayoutObservation] { controller.frozenRecent }
    func setEnabled(_ enabled: Bool) {
        settings.layoutDiagnosticsEnabled = enabled
        controller.setEnabled(enabled)
        notifyChange()
    }
    func freezeRecent() { controller.freezeRecent() }
    func clearTemporaryState() { controller.clearTemporaryState() }
    func bypassesJournal(bundleID: String) -> Bool {
        LayoutDiagnosticsController.bypassesJournal(editing: journalEditing, bundleID: bundleID, ownBundleID: ownBundleID)
    }
    func clearError() { lastError = nil; notifyChange() }
    private func notifyChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.changeScheduled = false
            NotificationCenter.default.post(name: .layoutDiagnosticsChanged, object: nil)
        }
    }
    private func finished(_ result: Result<Void, Error>) {
        if case .failure(let error) = result { lastError = error }
        notifyChange()
    }
}
