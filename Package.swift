// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "speech-server",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.76.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "speech-server",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MultipartKit", package: "multipart-kit"),
            ]
        ),
    ]
)
