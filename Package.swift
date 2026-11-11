// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MightyMouse",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MightyMouse",
            path: "Sources/MightyMouse",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
