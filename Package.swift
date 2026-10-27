// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SilentSnip",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SilentSnipCore", targets: ["SilentSnipCore"]),
        .library(name: "SilentSnipMac", targets: ["SilentSnipMac"]),
        .executable(name: "SilentSnip", targets: ["SilentSnipApp"]),
        .executable(name: "SilentSnipVerify", targets: ["SilentSnipVerify"])
    ],
    targets: [
        .target(name: "SilentSnipCore"),
        .target(name: "SilentSnipMac", dependencies: ["SilentSnipCore"]),
        .executableTarget(name: "SilentSnipApp", dependencies: ["SilentSnipCore", "SilentSnipMac"]),
        .executableTarget(name: "SilentSnipVerify", dependencies: ["SilentSnipCore", "SilentSnipMac"]),
        .testTarget(name: "SilentSnipCoreTests", dependencies: ["SilentSnipCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SilentSnipMacTests", dependencies: ["SilentSnipCore", "SilentSnipMac"])
    ]
)
