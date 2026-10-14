// swift-tools-version:6.0
import PackageDescription
import Foundation

let headless = ProcessInfo.processInfo.environment["PROXMACS_HEADLESS"] == "1"

let package = Package(
    name: "Proxmacs",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.35.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.10.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        .package(url: "https://github.com/facebook/zstd.git", from: "1.5.7"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CShims",
            path: "Sources/CShims",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .executableTarget(
            name: "Proxmacs",
            dependencies: [
                "CShims",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "libzstd", package: "zstd"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            path: "Sources/Proxmacs",
            exclude: headless ? ["UI", "App/ProxmacsApp.swift"] : [],
            swiftSettings: headless ? [.define("PROXMACS_HEADLESS")] : [],
            // Served from disk (copied into the .app by scripts/build-app.sh), not via Bundle.module.
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        .testTarget(
            name: "ProxmacsTests",
            dependencies: ["Proxmacs"],
            path: "Tests/ProxmacsTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
