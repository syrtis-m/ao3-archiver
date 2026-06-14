// swift-tools-version: 5.10
import PackageDescription

// AO3Kit holds the testable core (client, parser, store, sync, and the gallery read/
// filter/sort model). `ao3archiver` is the CLI; `AO3ArchiverApp` is the M2 SwiftUI gallery.
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
    ],
    targets: [
        .target(
            name: "AO3Kit",
            dependencies: [
                "SwiftSoup",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "ao3archiver",
            dependencies: ["AO3Kit"]
        ),
        // M2 SwiftUI gallery. A SwiftPM executable (not a shippable .app bundle yet — no
        // Info.plist/icon/entitlements/sandbox; that packaging + the security-scoped folder
        // bookmark are deferred). Views are a thin skin over AO3Kit's tested gallery model.
        .executableTarget(
            name: "AO3ArchiverApp",
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
