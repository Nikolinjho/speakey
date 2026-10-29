import CoreGraphics

/// Чужие события не передаются обработчику проверочного процесса.
enum NeuralTransportEventGate {
    static func accepts(type: CGEventType, event: CGEvent, marker: Int64, pid: Int64) -> Bool {
        type == .keyDown &&
        event.getIntegerValueField(.eventSourceUnixProcessID) == pid &&
        event.getIntegerValueField(.eventSourceUserData) == marker &&
        event.getIntegerValueField(.keyboardEventKeycode) == 255
    }
}
