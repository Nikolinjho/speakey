// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Speakey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Speakey",
            path: "Sources/Speakey",
            resources: [.process("Resources/RightLayout")],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
