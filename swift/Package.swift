// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZeroMcp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZeroMcp", targets: ["ZeroMcp"]),
        .executable(name: "zeromcp-example", targets: ["Example"]),
        .executable(name: "zeromcp-sandbox-test", targets: ["SandboxTest"]),
        .executable(name: "zeromcp-chaos-test", targets: ["ChaosTest"]),
        .executable(name: "zeromcp-timeout-test", targets: ["TimeoutTest"]),
        .executable(name: "zeromcp-bypass-test", targets: ["BypassTest"]),
        .executable(name: "zeromcp-credential-test", targets: ["CredentialTest"]),
        .executable(name: "zeromcp-resource-test", targets: ["ZeroMcpResourceTest"]),
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
        .executableTarget(
            name: "SandboxTest",
            dependencies: ["ZeroMcp"],
            path: "Sources/SandboxTest"
        ),
        .executableTarget(
            name: "ChaosTest",
            dependencies: ["ZeroMcp"],
            path: "Sources/ChaosTest"
        ),
        .executableTarget(
            name: "TimeoutTest",
            dependencies: ["ZeroMcp"],
            path: "Sources/TimeoutTest"
        ),
        .executableTarget(
            name: "BypassTest",
            dependencies: ["ZeroMcp"],
            path: "Sources/BypassTest"
        ),
        .executableTarget(
            name: "CredentialTest",
            dependencies: ["ZeroMcp"],
            path: "Sources/CredentialTest"
        ),
        .executableTarget(
            name: "ZeroMcpResourceTest",
            dependencies: ["ZeroMcp"],
            path: "Sources/ZeroMcpResourceTest"
        ),
        .testTarget(
            name: "ZeroMcpTests",
            dependencies: ["ZeroMcp"],
            path: "Tests/ZeroMcpTests"
        ),
    ]
)
