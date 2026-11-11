// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "eWheel",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "eWheel",
            path: "Sources/eWheel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
