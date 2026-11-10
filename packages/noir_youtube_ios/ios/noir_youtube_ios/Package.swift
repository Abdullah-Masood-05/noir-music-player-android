// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "noir_youtube_ios",
    platforms: [
        .iOS("13.0"),
    ],
    products: [
        .library(name: "noir-youtube-ios", targets: ["noir_youtube_ios"]),
    ],
    dependencies: [
        // MIT licence. Pinned to a commit after 0.4.10 (2026-10-31) that waits
        // out pre-roll ads instead of failing with HTTP 403. YouTube changes
        // often, so update deliberately.
        .package(url: "https://github.com/alexeichhorn/YouTubeKit", revision: "7f75a2299dc329c0b7855afb25d47663a02855cb"),
    ],
    targets: [
        .target(
            name: "noir_youtube_ios",
            dependencies: [
                .product(name: "YouTubeKit", package: "YouTubeKit"),
            ]
        ),
    ]
)
