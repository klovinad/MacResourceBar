// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacResourceBarCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacResourceBarCore", targets: ["MacResourceBarCore"])
    ],
    targets: [
        .target(
            name: "MacResourceBarCore",
            path: "NetworkMenuMonitor",
            exclude: ["AppDelegate.swift", "NetworkMenuMonitorApp.swift", "Views", "Assets.xcassets", "Info.plist"]
        ),
        .testTarget(
            name: "MacResourceBarCoreTests",
            dependencies: ["MacResourceBarCore"],
            path: "Tests/MacResourceBarCoreTests"
        )
    ]
)
