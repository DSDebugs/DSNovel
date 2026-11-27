// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSPluginKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DSPluginKit", targets: ["DSPluginKit"])
    ],
    dependencies: [
        .package(path: "../DSCore")
    ],
    targets: [
        .target(
            name: "DSPluginKit",
            dependencies: ["DSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSPluginKitTests",
            dependencies: ["DSPluginKit", "DSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
