// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "CullFeature",
    defaultLocalization: "ja",
    platforms: [.iOS(.v27)],
    products: [
        .library(name: "CullFeature", targets: ["CullFeature"]),
    ],
    targets: [
        .target(name: "CullFeature", swiftSettings: swiftSettings),
        .testTarget(
            name: "CullFeatureTests",
            dependencies: ["CullFeature"],
            swiftSettings: swiftSettings
        ),
    ]
)
