import Foundation

enum LocalBuildPolicyTests: DiagnosticSuite {
    static let name = "updates"
    static func run(_ t: DiagnosticTests) {
        t.check("Релиз сохраняет обновления", LocalBuildPolicy.updatesAllowed(bundleID: "ru.keyboop.app", localBuild: false))
        t.check("Dev не обновляется даже при KEYBOOP_UPDATER=1", !LocalBuildPolicy.updatesAllowed(bundleID: "ru.keyboop.app.dev", localBuild: false))
        t.check("Локальная сборка с произвольным ID не обновляется", !LocalBuildPolicy.updatesAllowed(bundleID: "custom.app", localBuild: true))
    }
}
