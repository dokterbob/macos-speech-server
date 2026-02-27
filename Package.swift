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
        // Pin to <1.1.0: swift-configuration 1.1.0 uses Data.bytes which only exists on macOS 26+.
        // async-http-client (transitive via vapor) accepts from: "1.0.0", so 1.0.x satisfies it.
        .package(url: "https://github.com/apple/swift-configuration.git", .upToNextMinor(from: "1.0.0")),
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
