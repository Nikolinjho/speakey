import Foundation
import CoreGraphics

enum MarkerTests: DiagnosticSuite {
    static let name = "marker"
    static func run(_ t: DiagnosticTests) {
        t.check("Нейромаркер имеет приоритет", InputEventOrigin.classify(sourceUserData: 1,
            syntheticMarker: 1, pauseMarker: 1, isNeuralMarker: true) == .neuralMarker)
        t.check("Обычный ввод остаётся реальным", InputEventOrigin.classify(sourceUserData: 0,
            syntheticMarker: 1, pauseMarker: 2) == .real)
        let codec = NeuralLayoutMarkerCodec(prefix: 0xfedcba98)
        for token in [UInt32(1), UInt32(Int32.max), UInt32.max] {
            let marker = codec.encode(token: token)
            t.check("Кодек сохраняет token \(token)", codec.token(from: marker) == token)
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 255, keyDown: true)!
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            let copy = event.copy()!
            t.check("CGEvent сохраняет все биты \(token)", copy.getIntegerValueField(.eventSourceUserData) == marker)
        }
        t.check("Нулевой token отклоняется", codec.token(from: codec.encode(token: 0)) == nil)
        t.check("Чужой prefix отклоняется", codec.token(from: NeuralLayoutMarkerCodec(prefix: 5).encode(token: 1)) == nil)
    }
}
