import Foundation

enum LocalBuildPolicyTests: DiagnosticSuite {
    static let name = "updates"
    static func run(_ t: DiagnosticTests) {
        t.check("Релиз без собственного сервера не обновляется", !LocalBuildPolicy.updatesAllowed(bundleID: "dev.speakey.app", localBuild: false))
        t.check("Dev не обновляется даже при SPEAKEY_UPDATER=1", !LocalBuildPolicy.updatesAllowed(bundleID: "dev.speakey.app.dev", localBuild: false))
        t.check("Локальная сборка с произвольным ID не обновляется", !LocalBuildPolicy.updatesAllowed(bundleID: "custom.app", localBuild: true))
    }
}
