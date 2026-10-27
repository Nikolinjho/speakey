import Foundation

func kbLog(_ message: String) {}
let expected = CommandLine.arguments[1]
let group = DispatchGroup()
group.enter()
DispatchQueue.global().async {
    defer { group.leave() }
    do {
        let loaded = try RightLayoutRuntimeFactory.load()
        guard expected == "disabled-profile", loaded.profile?.enabled == false,
              loaded.modelID == "rightlayout-ensemble-20-v1" else {
            fputs("FAIL: factory разрешил некорректный ресурс\n", stderr); exit(1)
        }
        let scores = try loaded.backend.predict("ghbdtn")
        precondition(scores.values.count == 9)
        print("PASS: Production factory загружает compiled model и disabled profile на worker")
    } catch {
        let accepted: Bool
        switch expected {
        case "invalid-manifest": accepted = (error as? NeuralLayoutError) == .invalidManifest
        case "invalid-json": accepted = error is DecodingError
        case "missing-resource": accepted = (error as? NeuralLayoutError) == .unavailable
        default: accepted = false
        }
        guard accepted else { fputs("FAIL: \(expected): \(error)\n", stderr); exit(1) }
        print("PASS: Production factory отклоняет \(expected)")
    }
}
guard group.wait(timeout: .now() + 15) == .success else { fputs("FAIL: factory timeout\n", stderr); exit(1) }
