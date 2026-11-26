// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSPlayback",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DSPlayback", targets: ["DSPlayback"])
    ],
    dependencies: [
        .package(path: "../DSCore"),
        .package(path: "../DSStorage"),
        .package(path: "../DSPluginKit")
    ],
    targets: [
        .target(
            name: "DSPlayback",
            dependencies: ["DSCore", "DSStorage", "DSPluginKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSPlaybackTests",
            dependencies: ["DSPlayback", "DSCore", "DSStorage", "DSPluginKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
