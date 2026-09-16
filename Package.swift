// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImageSmith",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ImageSmith",
            path: "Sources/ImageSmith",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "ImageSmithTests",
            dependencies: ["ImageSmith"],
            path: "Tests/ImageSmithTests"
        )
    ]
)
