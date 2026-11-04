// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaptureMac",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CaptureMac",
            path: "Sources/CaptureMac",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .testTarget(
            name: "CaptureMacTests",
            dependencies: ["CaptureMac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
