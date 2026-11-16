import Foundation
final class AppSettings { static let shared = AppSettings(); var language = "ru" }
enum CompletionModels { static let defaultID = "test-model" }
func kbLog(_ message: String) {}
