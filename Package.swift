// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NetBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NetBarCore", targets: ["NetBarCore"]),
        .executable(name: "NetBar", targets: ["NetBar"])
    ],
    targets: [
        .target(
            name: "NetBarCore",
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "NetBar",
            dependencies: ["NetBarCore"],
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "NetBarCoreTests",
            dependencies: ["NetBarCore"]
        )
    ]
)
