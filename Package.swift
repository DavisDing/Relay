// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "Relay", targets: ["Relay"])
    ],
    targets: [
        .executableTarget(
            name: "Relay",
            path: "Sources/Relay"
        )
    ]
)
