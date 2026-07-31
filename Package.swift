// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Conn",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ConnDomain", targets: ["ConnDomain"]),
        .library(name: "ConnAppCore", targets: ["ConnAppCore"]),
        .library(name: "ConnCodexAdapter", targets: ["ConnCodexAdapter"]),
        .library(name: "ConnPiAdapter", targets: ["ConnPiAdapter"]),
        .library(name: "ConnUI", targets: ["ConnUI"]),
        .executable(name: "Conn", targets: ["ConnApp"]),
        .executable(name: "conn-domain-tests", targets: ["ConnDomainTests"]),
        .executable(name: "conn-app-core-tests", targets: ["ConnAppCoreTests"]),
        .executable(
            name: "conn-codex-adapter-tests",
            targets: ["ConnCodexAdapterTests"]
        ),
        .executable(
            name: "conn-pi-adapter-tests",
            targets: ["ConnPiAdapterTests"]
        ),
        .executable(name: "conn-ui-tests", targets: ["ConnUITests"]),
        .executable(name: "conn-packaging-probe", targets: ["ConnPackagingProbe"]),
    ],
    targets: [
        .target(name: "ConnDomain"),
        .target(
            name: "ConnAppCore",
            dependencies: ["ConnDomain"]
        ),
        .executableTarget(
            name: "ConnApp",
            dependencies: [
                "ConnDomain",
                "ConnAppCore",
                "ConnCodexAdapter",
                "ConnPiAdapter",
                "ConnUI",
            ]
        ),
        .target(
            name: "ConnUI",
            dependencies: ["ConnDomain", "ConnAppCore"]
        ),
        .executableTarget(
            name: "ConnDomainTests",
            dependencies: ["ConnDomain"],
            path: "Tests/ConnDomainTests"
        ),
        .executableTarget(
            name: "ConnAppCoreTests",
            dependencies: ["ConnAppCore", "ConnDomain"],
            path: "Tests/ConnAppCoreTests"
        ),
        .target(
            name: "ConnCodexAdapter",
            dependencies: ["ConnDomain"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ConnCodexAdapterTests",
            dependencies: ["ConnCodexAdapter", "ConnAppCore", "ConnDomain"],
            path: "Tests/ConnCodexAdapterTests"
        ),
        .target(
            name: "ConnPiAdapter",
            dependencies: ["ConnDomain"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ConnPiAdapterTests",
            dependencies: ["ConnPiAdapter", "ConnDomain"],
            path: "Tests/ConnPiAdapterTests"
        ),
        .executableTarget(
            name: "ConnUITests",
            dependencies: [
                "ConnUI",
                "ConnAppCore",
                "ConnDomain",
            ],
            path: "Tests/ConnUITests"
        ),
        .executableTarget(name: "ConnPackagingProbe"),
    ]
)
