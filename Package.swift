// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadRead",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ReadRead",
            path: "Sources/ReadRead",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
