import Foundation

enum LocalBuildPolicy {
    static func updatesAllowed(bundleID: String?, localBuild: Bool) -> Bool {
        false
    }
    static var updatesAllowed: Bool {
        updatesAllowed(bundleID: Bundle.main.bundleIdentifier,
                       localBuild: Bundle.main.object(forInfoDictionaryKey: "SpeakeyLocalBuild") as? Bool ?? false)
    }
}
