// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Island",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "IslandApp", targets: ["IslandApp"]),
        .executable(name: "IslandBridge", targets: ["IslandBridge"]),
        .library(name: "IslandShared", targets: ["IslandShared"])
    ],
    targets: [
        .target(
            name: "IslandShared"
        ),
        .executableTarget(
            name: "IslandApp",
            dependencies: ["IslandShared"],
            path: "Sources/IslandApp"
        ),
        .executableTarget(
            name: "IslandBridge",
            dependencies: ["IslandShared"],
            path: "Sources/IslandBridge"
        ),
        .testTarget(
            name: "IslandTests",
            dependencies: ["IslandShared", "IslandApp"],
            path: "Tests/IslandTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
