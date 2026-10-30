// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FunFan",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FunFanCore", targets: ["FunFanCore"]),
        .executable(name: "funfanctl", targets: ["FunFanCtl"]),
    ],
    targets: [
        .target(
            name: "FunFanCore",
            path: "FunFanCore"
        ),
        .testTarget(
            name: "FunFanCoreTests",
            dependencies: ["FunFanCore"],
            path: "Tests/FunFanCoreTests"
        ),
        .executableTarget(
            name: "FunFanProbe",
            dependencies: ["FunFanCore"],
            path: "FunFanProbe"
        ),
        .executableTarget(
            name: "FunFanCtl",
            dependencies: ["FunFanCore"],
            path: "FunFanCtl"
        ),
        .executableTarget(
            name: "FunFanHelper",
            dependencies: ["FunFanCore"],
            path: "FunFanHelper"
        ),
        .executableTarget(
            name: "FunFan",
            dependencies: ["FunFanCore"],
            path: "FunFan"
        ),
    ]
)
