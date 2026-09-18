// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Cutdown",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CutdownCore", targets: ["CutdownCore"]),
        .library(name: "CutdownMac", targets: ["CutdownMac"]),
        .executable(name: "Cutdown", targets: ["CutdownApp"]),
        .executable(name: "CutdownVerify", targets: ["CutdownVerify"])
    ],
    targets: [
        .target(name: "CutdownCore"),
        .target(name: "CutdownMac", dependencies: ["CutdownCore"]),
        .executableTarget(name: "CutdownApp", dependencies: ["CutdownCore", "CutdownMac"]),
        .executableTarget(name: "CutdownVerify", dependencies: ["CutdownCore", "CutdownMac"]),
        .testTarget(name: "CutdownCoreTests", dependencies: ["CutdownCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CutdownMacTests", dependencies: ["CutdownCore", "CutdownMac"])
    ]
)
