// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Panes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Panes",
            path: "Sources/Panes",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
