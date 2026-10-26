import Foundation

enum LocalBuildPolicy {
    static func updatesAllowed(bundleID: String?, localBuild: Bool) -> Bool {
        !localBuild && !(bundleID ?? "").hasSuffix(".dev")
    }
    static var updatesAllowed: Bool {
        updatesAllowed(bundleID: Bundle.main.bundleIdentifier,
                       localBuild: Bundle.main.object(forInfoDictionaryKey: "KeyboopLocalBuild") as? Bool ?? false)
    }
}
