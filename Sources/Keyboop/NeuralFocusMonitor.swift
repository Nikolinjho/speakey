import Foundation

// Инъекция регистрации позволяет проверить события фокуса без Accessibility и чужих процессов.
final class NeuralFocusMonitor {
    typealias Install = (Int32, @escaping () -> Void) -> (() -> Void)?
    private let install: Install
    private let changed: () -> Void
    private var cancel: (() -> Void)?
    private var pid: Int32?
    private(set) var available = false

    init(install: @escaping Install, changed: @escaping () -> Void) {
        self.install = install
        self.changed = changed
    }

    deinit { cancel?() }

    func track(pid: Int32?) {
        precondition(Thread.isMainThread)
        guard self.pid != pid else { return }
        stop()
        self.pid = pid
        changed()
        guard let pid else { return }
        cancel = install(pid) { [weak self] in self?.changed() }
        available = cancel != nil
    }

    func stop() {
        precondition(Thread.isMainThread)
        cancel?()
        cancel = nil
        pid = nil
        available = false
    }
}
