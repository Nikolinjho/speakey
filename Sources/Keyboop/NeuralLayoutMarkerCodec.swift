import Foundation

struct NeuralLayoutMarkerCodec {
    let prefix: UInt32
    func encode(token: UInt32) -> Int64 {
        Int64(bitPattern: (UInt64(prefix) << 32) | UInt64(token))
    }
    func token(from marker: Int64) -> UInt32? {
        let bits = UInt64(bitPattern: marker)
        let token = UInt32(truncatingIfNeeded: bits)
        guard UInt32(truncatingIfNeeded: bits >> 32) == prefix, token != 0 else { return nil }
        return token
    }
}
