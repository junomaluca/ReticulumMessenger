// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReticulumKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ReticulumKit",
            targets: ["ReticulumKit"]
        ),
        .library(
            name: "LXMFKit",
            targets: ["LXMFKit"]
        ),
    ],
    targets: [
        // C wrapper for CommonCrypto (AES-CBC support)
        .target(
            name: "CCommonCrypto",
            path: "Sources/CCommonCrypto"
        ),
        // Reticulum Network Stack
        .target(
            name: "ReticulumKit",
            dependencies: ["CCommonCrypto"],
            path: "Sources/ReticulumKit"
        ),
        // LXMF Messaging Protocol
        .target(
            name: "LXMFKit",
            dependencies: ["ReticulumKit"],
            path: "Sources/LXMFKit"
        ),
        // Tests
        .testTarget(
            name: "ReticulumKitTests",
            dependencies: ["ReticulumKit"],
            path: "Tests/ReticulumKitTests"
        ),
        .testTarget(
            name: "LXMFKitTests",
            dependencies: ["LXMFKit"],
            path: "Tests/LXMFKitTests"
        ),
    ]
)
