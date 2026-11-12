// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MouseHerdr",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MouseHerdr",
            path: "Sources/MouseHerdr",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
