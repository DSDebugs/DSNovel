// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSStorage",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "DSStorage", targets: ["DSStorage"])
    ],
    dependencies: [
        .package(path: "../DSCore")
    ],
    targets: [
        .target(
            name: "DSStorage",
            dependencies: ["DSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DSStorageTests",
            dependencies: ["DSStorage", "DSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
