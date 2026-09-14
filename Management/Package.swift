// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SpeechServerManagement",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SpeechServerManagement", targets: ["SpeechServerManagement"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1")],
    targets: [
        .target(name: "SpeechServerManagement", dependencies: [.product(name: "Yams", package: "Yams")]),
        .testTarget(name: "SpeechServerManagementTests", dependencies: ["SpeechServerManagement"]),
    ]
)
