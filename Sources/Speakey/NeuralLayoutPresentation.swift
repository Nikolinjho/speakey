import Foundation

struct NeuralLayoutPresentation {
    let mode: NeuralLayoutMode
    let status: NeuralLayoutRuntime.Status
    let error: String?
    let assistanceAvailable: Bool
    var effectiveMode: NeuralLayoutMode { mode == .assist && !assistanceAvailable ? .observe : mode }
}

// Только снимки состояния: хранилище не создаёт движок или модель.
final class NeuralLayoutPresentationStore {
    static let shared = NeuralLayoutPresentationStore()
    static let changed = Notification.Name("neuralLayoutPresentationChanged")
    private(set) var value = NeuralLayoutPresentation(mode: .off, status: .off, error: nil, assistanceAvailable: false)
    let notifications = NotificationCenter()

    func publish(_ value: NeuralLayoutPresentation) {
        precondition(Thread.isMainThread)
        self.value = value
        notifications.post(name: Self.changed, object: nil)
    }
}
