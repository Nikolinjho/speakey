import Foundation
func kbLog(_ message: String) {}
enum AutocompletePrefs { static let idleUnloadMinutes = 60 }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("completion-engine-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
setenv("SPEAKEY_COMPLETE_TEST_DIR", directory.path, 1)
let pid = directory.appendingPathComponent("complete.pid")
let socketFile = URL(fileURLWithPath: CompletionEngine.socketPath)
try Data("12345".utf8).write(to: pid)
try Data("other owner".utf8).write(to: socketFile)
CompletionEngine.shared.stop()
let preserved = (try? Data(contentsOf: pid)) == Data("12345".utf8)
    && (try? Data(contentsOf: socketFile)) == Data("other owner".utf8)
print("completion engine ownership: \(preserved ? "PASS" : "FAIL") — не запущенный экземпляр сохраняет чужие pid/socket")
exit(preserved ? 0 : 1)
