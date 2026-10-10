// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Shelfy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Shelfy", path: "Sources/Shelfy")
    ]
)
