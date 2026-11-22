// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSDesignSystem",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DSDesignSystem", targets: ["DSDesignSystem"])
    ],
    dependencies: [
        .package(path: "../DSCore")
    ],
    targets: [
        .target(
            name: "DSDesignSystem",
            dependencies: ["DSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSDesignSystemTests",
            dependencies: ["DSDesignSystem", "DSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
