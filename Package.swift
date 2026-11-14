// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DSNovel",
    platforms: [
        .iOS("27.0")
    ],
    products: [
        .library(name: "DSNovel", targets: ["DSNovel"])
    ],
    targets: [
        .target(
            name: "DSNovel",
            path: "Sources/DSNovel",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
