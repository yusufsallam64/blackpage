// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blackpage",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Blackpage", path: "Sources/Blackpage")
    ]
)
