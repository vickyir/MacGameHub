// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacGameHub",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacGameHub", targets: ["MacGameHub"]),
        .library(name: "HubCore", targets: ["HubCore"]),
    ],
    targets: [
        // Pure logic: models, persistence, Wine engine, game scanning. Foundation only.
        .target(name: "HubCore"),
        // SwiftUI front-end.
        .executableTarget(name: "MacGameHub", dependencies: ["HubCore"]),
        // Requires full Xcode (XCTest). Run with: swift test
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"]),
    ]
)
