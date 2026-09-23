// swift-tools-version: 5.10
import PackageDescription

// AO3Kit holds the testable core (client, parser, store, sync, gallery model, reader,
// Kindle export). `ao3archiver` is the CLI; `AO3ArchiverApp` is the SwiftUI app.
//
// Platform is macOS 26 ("Tahoe"): one deployment boundary so the real Liquid Glass
// materials (`.glassEffect`) and the Observation framework are available everywhere with
// no scattered `@available` branches. The whole product targets macOS 26 by design — the
// dark liquid-glass UI is the point — so there's no older-OS render path to maintain.
let package = Package(
    name: "AO3Archiver",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AO3Kit", targets: ["AO3Kit"]),
        .executable(name: "ao3archiver", targets: ["ao3archiver"]),
        .executable(name: "AO3ArchiverApp", targets: ["AO3ArchiverApp"]),
    ],
    dependencies: [
        // HTML parsing. We use it as a tool; the parsing *logic* is our own (see BlurbParser).
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
        // SQLite metadata store (schema, migrations, FTS5). Links the system libsqlite3.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        // ZIP reader/writer (an EPUB is a ZIP). Powers the in-app reader: read the
        // container/OPF/content entries and extract them for WKWebView; also writes the
        // synthetic EPUB the reader tests parse. MIT, like SwiftSoup/GRDB.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "AO3Kit",
            dependencies: [
                "SwiftSoup",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "ao3archiver",
            dependencies: ["AO3Kit"]
        ),
        // The SwiftUI app. A SwiftPM executable; Packaging/make-app.sh wraps it into a
        // double-clickable, ad-hoc-signed, non-sandboxed "AO3 Archiver.app". Views are a thin
        // skin over AO3Kit's tested model.
        .executableTarget(
            name: "AO3ArchiverApp",
            dependencies: ["AO3Kit"]
        ),
        // Headless parser verification that runs under a Command Line Tools–only
        // toolchain (where `swift test` can't link XCTest/Testing). CI with full Xcode
        // runs the richer suite in Tests/AO3KitTests instead.
        // Stub-AO3 harness (a `URLProtocol` + canned listing/work pages) shared by BOTH test
        // runners, so `SyncEngine` can be exercised end-to-end with zero network access.
        .target(
            name: "AO3KitTestSupport",
            dependencies: ["AO3Kit"]
        ),
        .executableTarget(
            name: "selftest",
            dependencies: [
                "AO3Kit",
                "AO3KitTestSupport",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "AO3KitTests",
            dependencies: [
                "AO3Kit",
                "AO3KitTestSupport",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
