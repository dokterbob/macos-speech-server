// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeechServerApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Management")
    ],
    targets: [
        .executableTarget(
            name: "SpeechServerApp",
            dependencies: [
                .product(name: "SpeechServerManagement", package: "Management")
            ]
        )
    ]
)
