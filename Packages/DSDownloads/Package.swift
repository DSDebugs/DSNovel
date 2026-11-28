// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSDownloads",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DSDownloads", targets: ["DSDownloads"])
    ],
    dependencies: [
        .package(path: "../DSCore"),
        .package(path: "../DSStorage"),
        .package(path: "../DSPluginKit")
    ],
    targets: [
        .target(
            name: "DSDownloads",
            dependencies: ["DSCore", "DSStorage", "DSPluginKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSDownloadsTests",
            dependencies: ["DSDownloads", "DSCore", "DSStorage", "DSPluginKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
