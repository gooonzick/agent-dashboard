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
        .target(name: "AppShell", dependencies: ["CoreModels"], swiftSettings: strict),
        .testTarget(name: "CoreModelsTests", dependencies: ["CoreModels"], swiftSettings: strict),
    ]
)
