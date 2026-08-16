// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AskDroid",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "AskDroid", targets: ["AskDroid"]),
        .executable(name: "AskDroidScreenshots", targets: ["AskDroidScreenshots"]),
        .library(name: "AskDroidKit", targets: ["AskDroidKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(
            name: "AskDroidKit",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/AskDroid"
        ),
        .executableTarget(
            name: "AskDroid",
            dependencies: ["AskDroidKit"],
            path: "Sources/AskDroidMain"
        ),
        .executableTarget(
            name: "AskDroidScreenshots",
            dependencies: ["AskDroidKit"],
            path: "Sources/AskDroidScreenshots"
        ),
        .testTarget(
            name: "AskDroidTests",
            dependencies: ["AskDroidKit"],
            path: "Tests/AskDroidTests"
        ),
    ]
)
