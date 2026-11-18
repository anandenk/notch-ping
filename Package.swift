// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchPing",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchPing", targets: ["NotchPing"]),
        .executable(name: "notch-relay", targets: ["NotchRelay"])
    ],
    targets: [
        .target(name: "NotchCore"),
        .executableTarget(name: "NotchRelay", dependencies: ["NotchCore"]),
        .executableTarget(name: "NotchPing", dependencies: ["NotchCore"]),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "NotchPing"])
    ]
)
