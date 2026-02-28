// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "speech-server",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.76.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1"),
        // async-http-client 1.31+ depends on swift-configuration, which uses Data.bytes.
        // Data.bytes requires macOS 26+ Foundation and is absent on macOS 15 CI runners.
        // Pin to <1.31 to drop the swift-configuration transitive dependency.
        .package(url: "https://github.com/swift-server/async-http-client.git", "1.24.0"..<"1.31.0"),
    ],
    targets: [
        .executableTarget(
            name: "speech-server",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MultipartKit", package: "multipart-kit"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "speech-serverTests",
            dependencies: [
                .target(name: "speech-server"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
