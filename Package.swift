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
            // Info.plist and the asset catalog are handled by xtool.yml
            // (infoPath / iconPath), and by XcodeGen on the macOS path.
            // Excluding them here avoids actool being invoked on Linux/WSL.
            exclude: [
                "Resources/Info.plist",
                "Resources/Assets.xcassets"
            ],
            resources: [
                .copy("Resources/Plugins")
            ]
        )
    ]
)
