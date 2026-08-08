// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YeelightLibra",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "YeelightLibra",
            path: "Sources/YeelightLibra"
        )
    ]
)
