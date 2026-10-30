// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "Core",
    platforms: [.macOS(.v26)],
    products: [
        // The only product the app links; every other target is internal to the package.
        .library(name: "AppShell", targets: ["AppShell"]),
    ],
    targets: [
        .target(name: "CoreModels", swiftSettings: strict),
        .target(name: "Shell", swiftSettings: strict),
        .target(name: "Discovery", dependencies: ["CoreModels"], swiftSettings: strict),
        .target(name: "GitKit", dependencies: ["CoreModels", "Shell"], swiftSettings: strict),
        .target(name: "AppShell", dependencies: ["CoreModels"], swiftSettings: strict),
        // Helpers shared by the test targets: temporary folders, and real git repositories to run tests against.
        .target(name: "TestSupport", dependencies: ["Shell"], path: "Tests/TestSupport", swiftSettings: strict),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "ShellTests", dependencies: ["Shell", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery", "TestSupport"], swiftSettings: strict),
        .testTarget(
            name: "GitKitTests", dependencies: ["GitKit", "CoreModels", "Shell", "TestSupport"],
            swiftSettings: strict),
    ]
)
