import Foundation

extension Notification.Name {
    static let neuralLayoutModeChanged = Notification.Name("neuralLayoutModeChanged")
}

// Общий codec используется AppSettings и независимым от AppKit проверочным executable.
enum NeuralLayoutModeSettings {
    static func read(_ defaults: UserDefaults) -> NeuralLayoutMode {
        guard let raw = defaults.string(forKey: "neuralLayoutMode") else { return .observe }
        return NeuralLayoutMode(rawValue: raw) ?? .off
    }

    static func write(_ mode: NeuralLayoutMode, to defaults: UserDefaults) {
        guard mode != read(defaults) else { return }
        defaults.set(mode.rawValue, forKey: "neuralLayoutMode")
        NotificationCenter.default.post(name: .neuralLayoutModeChanged, object: nil)
    }
}
