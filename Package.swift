// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ImageSmith",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "ImageSmith",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ImageSmith",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            // Scripts/build-app.sh embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "ImageSmithTests",
            dependencies: ["ImageSmith"],
            path: "Tests/ImageSmithTests"
        )
    ]
)
