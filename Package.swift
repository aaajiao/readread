// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ReadRead",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "ReadRead",
            path: "Sources/ReadRead",
            // The icons are build-script inputs (scripts/build-app.sh copies them
            // into Contents/Resources). No SwiftPM resources means no generated
            // Bundle.module accessor, which crashed the release app at launch.
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "ReadReadTests",
            dependencies: ["ReadRead"],
            path: "Tests/ReadReadTests"
        ),
    ]
)
