// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSCore",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DSCore", targets: ["DSCore"])
    ],
    targets: [
        .target(
            name: "DSCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSCoreTests",
            dependencies: ["DSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
