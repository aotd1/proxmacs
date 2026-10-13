// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Proxmacs",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Proxmacs",
            path: "Sources/Proxmacs"
        ),
        .testTarget(
            name: "ProxmacsTests",
            dependencies: ["Proxmacs"],
            path: "Tests/ProxmacsTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
