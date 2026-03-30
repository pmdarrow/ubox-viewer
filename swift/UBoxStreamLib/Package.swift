// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ubox-viewer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UBoxStreamLib", targets: ["UBoxStreamLib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "UBoxStreamLib",
            path: "Sources/UBoxStreamLib"
        ),
        .executableTarget(
            name: "ubox-viewer",
            dependencies: [
                "UBoxStreamLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/UBoxCLI"
        ),
    ]
)
