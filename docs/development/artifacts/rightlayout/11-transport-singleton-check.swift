import AppKit
final class FixtureApplication: NSApplication {}
let app = FixtureApplication.shared as! FixtureApplication
app.setActivationPolicy(.prohibited)
app.finishLaunching()
print("PASS: custom NSApplication singleton without activation")
