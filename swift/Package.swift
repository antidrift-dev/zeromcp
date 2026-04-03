// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZeroMcp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZeroMcp", targets: ["ZeroMcp"]),
        .executable(name: "zeromcp-example", targets: ["Example"]),
    ],
    targets: [
        .target(
            name: "ZeroMcp",
            path: "Sources/ZeroMcp"
        ),
        .executableTarget(
            name: "Example",
            dependencies: ["ZeroMcp"],
            path: "Sources/Example"
        ),
        .testTarget(
            name: "ZeroMcpTests",
            dependencies: ["ZeroMcp"],
            path: "Tests/ZeroMcpTests"
        ),
    ]
)
