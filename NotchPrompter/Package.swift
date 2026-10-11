// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchPrompter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchPrompter")
    ]
)
