import Foundation
import ApplicationServices

// Регистрация выполняется при смене приложения, AX callback только сбрасывает нейросессию.
enum AXNeuralFocusSource {
    static func install(pid: Int32, changed: @escaping () -> Void) -> (() -> Void)? {
        precondition(Thread.isMainThread)
        guard let registration = Registration(pid: pid, changed: changed) else { return nil }
        return { registration.stop() }
    }

    private final class Registration {
        private var observer: AXObserver?
        private let application: AXUIElement
        private let changed: () -> Void
        private let notifications = [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification]

        init?(pid: Int32, changed: @escaping () -> Void) {
            application = AXUIElementCreateApplication(pid)
            self.changed = changed
            let status = AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue().changed()
            }, &observer)
            guard status == .success, let observer else { return nil }
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in notifications {
                guard AXObserverAddNotification(observer, application, notification as CFString, context) == .success else {
                    stop()
                    return nil
                }
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        deinit { stop() }

        func stop() {
            guard let observer else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for notification in notifications {
                AXObserverRemoveNotification(observer, application, notification as CFString)
            }
            self.observer = nil
        }
    }
}
