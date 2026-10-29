import Foundation

let neuralLayoutMarkerCodec: NeuralLayoutMarkerCodec = {
    let forbidden = Set([UInt32(0), UInt32(truncatingIfNeeded: UInt64(bitPattern: kbSyntheticMarker) >> 32),
                         UInt32(truncatingIfNeeded: UInt64(bitPattern: kbPauseFixMarker) >> 32)])
    var prefix: UInt32 = 0
    repeat { prefix = UInt32.random(in: 1...UInt32.max) } while forbidden.contains(prefix)
    return NeuralLayoutMarkerCodec(prefix: prefix)
}()
