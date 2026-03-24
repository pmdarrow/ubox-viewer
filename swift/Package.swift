// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ubox-stream",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "ubox-stream",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/UBoxStream"
        ),
    ]
)
