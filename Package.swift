// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArcaSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ArcaSDK", targets: ["ArcaSDK"]),
    ],
    targets: [
        .target(
            name: "ArcaSDK",
            path: "Sources/ArcaSDK"
        ),
        .testTarget(
            name: "ArcaSDKTests",
            dependencies: ["ArcaSDK"],
            path: "Tests/ArcaSDKTests"
        ),
    ]
)
