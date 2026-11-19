// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentBar",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "AgentBarCore", targets: ["AgentBarCore"]),
        .executable(name: "AgentBar", targets: ["AgentBarApp"]),
        .executable(name: "agentbar-hook", targets: ["agentbar-hook"])
    ],
    targets: [
        .target(
            name: "AgentBarCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "AgentBarApp",
            dependencies: ["AgentBarCore"]
        ),
        .executableTarget(
            name: "agentbar-hook",
            dependencies: ["AgentBarCore"]
        ),
        .testTarget(
            name: "AgentBarCoreTests",
            dependencies: ["AgentBarCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
