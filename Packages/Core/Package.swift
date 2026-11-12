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
        .target(name: "GitKit", dependencies: ["CoreModels", "Shell", "ProcessKit", "Safety"], swiftSettings: strict),
        .target(name: "Hosting", dependencies: ["CoreModels", "Shell"], swiftSettings: strict),
        .target(name: "DiskUsage", dependencies: ["CoreModels"], swiftSettings: strict),
        .target(name: "ProcessKit", dependencies: ["CoreModels"], swiftSettings: strict),
        .target(name: "Safety", dependencies: ["CoreModels"], swiftSettings: strict),
        .target(name: "Cleanup", dependencies: ["CoreModels", "Shell", "DiskUsage"], swiftSettings: strict),
        .target(
            name: "Dashboard",
            dependencies: [
                "CoreModels", "Shell", "Discovery", "GitKit", "Hosting", "DiskUsage", "ProcessKit", "Safety", "Cleanup",
            ],
            swiftSettings: strict),
        .target(name: "AppShell", dependencies: ["CoreModels", "Dashboard", "Hosting", "Safety"], swiftSettings: strict),
        // Helpers shared by the test targets: temporary folders, real git repositories to run tests against, and
        // processes that exist only in a test.
        .target(
            name: "TestSupport", dependencies: ["Shell", "CoreModels", "ProcessKit"], path: "Tests/TestSupport",
            swiftSettings: strict),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "ShellTests", dependencies: ["Shell", "TestSupport"], swiftSettings: strict),
        .testTarget(name: "DiscoveryTests", dependencies: ["Discovery", "TestSupport"], swiftSettings: strict),
        .testTarget(
            name: "GitKitTests",
            dependencies: ["GitKit", "CoreModels", "Shell", "ProcessKit", "Safety", "TestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "HostingTests", dependencies: ["Hosting", "CoreModels", "Shell"], resources: [.copy("Fixtures")],
            swiftSettings: strict),
        .testTarget(
            name: "DiskUsageTests", dependencies: ["DiskUsage", "CoreModels", "Shell", "TestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "ProcessKitTests", dependencies: ["ProcessKit", "CoreModels", "TestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "CleanupTests", dependencies: ["Cleanup", "Shell", "CoreModels", "TestSupport"],
            resources: [.copy("Fixtures")], swiftSettings: strict),
        .testTarget(name: "SafetyTests", dependencies: ["Safety", "CoreModels"], swiftSettings: strict),
        .testTarget(
            name: "AppShellTests", dependencies: ["AppShell", "Dashboard", "CoreModels", "Hosting", "Safety"],
            swiftSettings: strict),
        .testTarget(
            name: "DashboardTests",
            dependencies: [
                "Dashboard", "CoreModels", "Shell", "Discovery", "GitKit", "Hosting", "DiskUsage", "ProcessKit",
                "Safety", "Cleanup", "TestSupport",
            ],
            swiftSettings: strict),
    ]
)
