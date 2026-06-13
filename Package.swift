// swift-tools-version: 5.10
import PackageDescription

// M0 spike: a runnable core that proves the riskiest AO3 mechanics
// (auth + polite rate limiting + bookmark parsing + EPUB download)
// before any SwiftUI is written. The SwiftUI app target is added in M2.
let package = Package(
    name: "AO3Archiver",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AO3Kit", targets: ["AO3Kit"]),
        .executable(name: "ao3archiver", targets: ["ao3archiver"]),
    ],
    dependencies: [
        // HTML parsing. We use it as a tool; the parsing *logic* is our own (see BlurbParser).
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "AO3Kit",
            dependencies: ["SwiftSoup"]
        ),
        .executableTarget(
            name: "ao3archiver",
            dependencies: ["AO3Kit"]
        ),
        // Headless parser verification that runs under a Command Line Tools–only
        // toolchain (where `swift test` can't link XCTest/Testing). CI with full Xcode
        // runs the richer suite in Tests/AO3KitTests instead.
        .executableTarget(
            name: "selftest",
            dependencies: ["AO3Kit"]
        ),
        .testTarget(
            name: "AO3KitTests",
            dependencies: ["AO3Kit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
