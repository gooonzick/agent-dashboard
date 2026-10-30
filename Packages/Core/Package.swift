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
        .target(name: "AppShell", dependencies: ["CoreModels"], swiftSettings: strict),
        // Helpers shared by the test targets (temporary folders now; spawned processes and git repositories later).
        .target(name: "TestSupport", path: "Tests/TestSupport", swiftSettings: strict),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "ShellTests", dependencies: ["Shell", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery", "TestSupport"], swiftSettings: strict),
    ]
)
