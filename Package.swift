// swift-tools-version:5.9
import PackageDescription

// No external dependencies, by design. See README "Why no AWS SDK".
let package = Package(
    name: "Watchtower",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Watchtower", path: "Sources/Watchtower")
    ]
)
