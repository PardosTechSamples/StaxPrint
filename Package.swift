// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StaxPrint",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StaxPrint", targets: ["StaxPrint"]),
        .executable(name: "instax-tool", targets: ["instax-tool"]),
        .library(name: "InstaxKit", targets: ["InstaxKit"]),
    ],
    targets: [
        // SP-2 protocol, image layout, TCP client and the Core Image photo pipeline.
        .target(name: "InstaxKit"),
        // A fake SP-2 TCP server, used by the tests and by `instax-tool fake-server`.
        .target(name: "InstaxFake", dependencies: ["InstaxKit"]),
        // The SwiftUI app (StaxPrint).
        .executableTarget(name: "StaxPrint", dependencies: ["InstaxKit"], resources: [.process("Resources")]),
        // Command-line helper: status query, encoding dumps for cross-checking, fake server.
        .executableTarget(name: "instax-tool", dependencies: ["InstaxKit", "InstaxFake"]),
        .testTarget(name: "InstaxKitTests", dependencies: ["InstaxKit", "InstaxFake"]),
    ]
)
