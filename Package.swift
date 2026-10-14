// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Margin",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MarginKit"),
        .executableTarget(name: "Margin", dependencies: ["MarginKit"]),
        .testTarget(name: "MarginKitTests", dependencies: ["MarginKit"]),
    ]
)
