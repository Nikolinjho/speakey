import CoreGraphics
import Foundation

@main
struct TransportGateTests {
    static func main() {
        let pid = Int64(getpid())
        let marker: Int64 = -0x1234_5678_1234_5678
        func accepts(marker supplied: Int64 = marker, eventPID: Int64 = pid,
                     key: CGKeyCode = 255, type: CGEventType = .keyDown) -> Bool {
            let source = CGEventSource(stateID: .privateState)!
            source.userData = supplied
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)!
            event.setIntegerValueField(.eventSourceUnixProcessID, value: eventPID)
            return NeuralTransportEventGate.accepts(type: type, event: event, marker: marker, pid: pid)
        }
        precondition(accepts(), "Собственный полный маркер должен пройти")
        precondition(!accepts(marker: marker ^ (1 << 40)), "Изменение старших битов должно отклоняться")
        precondition(!accepts(eventPID: pid + 1), "Чужой PID должен проходить мимо проверки")
        precondition(!accepts(key: 0), "Печатающая клавиша должна проходить мимо проверки")
        precondition(!accepts(type: .keyUp), "Отпускание клавиши должно проходить мимо проверки")
        print("PASS: 5 transport gate assertions")
    }
}
