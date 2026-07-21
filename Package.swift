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
        .library(name: "ConnAppServerAdapter", targets: ["ConnAppServerAdapter"]),
        .executable(name: "Conn", targets: ["ConnApp"]),
        .executable(name: "conn-domain-tests", targets: ["ConnDomainTests"]),
        .executable(name: "conn-app-core-tests", targets: ["ConnAppCoreTests"]),
        .executable(
            name: "conn-app-server-adapter-tests",
            targets: ["ConnAppServerAdapterTests"]
        ),
        .executable(name: "conn-packaging-probe", targets: ["ConnPackagingProbe"]),
    ],
    targets: [
        .target(name: "ConnDomain"),
        .target(
            name: "ConnAppCore",
            dependencies: ["ConnDomain", "ConnAppServerAdapter"]
        ),
        .executableTarget(
            name: "ConnApp",
            dependencies: ["ConnDomain", "ConnAppCore"]
        ),
        .executableTarget(
            name: "ConnDomainTests",
            dependencies: ["ConnDomain"],
            path: "Tests/ConnDomainTests"
        ),
        .executableTarget(
            name: "ConnAppCoreTests",
            dependencies: [
                "ConnAppCore",
                "ConnDomain",
                "ConnAppServerAdapter",
            ],
            path: "Tests/ConnAppCoreTests"
        ),
        .target(name: "ConnAppServerAdapter"),
        .executableTarget(
            name: "ConnAppServerAdapterTests",
            dependencies: ["ConnAppServerAdapter"],
            path: "Tests/ConnAppServerAdapterTests"
        ),
        .executableTarget(name: "ConnPackagingProbe"),
    ]
)
