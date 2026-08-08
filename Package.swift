// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YeelightLibra",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "YeelightLibraCore",
            path: "Sources/YeelightLibraCore"
        ),
        .executableTarget(
            name: "YeelightLibra",
            dependencies: ["YeelightLibraCore"],
            path: "Sources/YeelightLibra"
        ),
        .testTarget(
            name: "YeelightLibraTests",
            dependencies: ["YeelightLibraCore"]
        )
    ]
)
