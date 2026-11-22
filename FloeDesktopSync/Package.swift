// swift-tools-version: 6.2
// SPDX-License-Identifier: MPL-2.0
import PackageDescription

// Independent persistence foundation for the Floe cross-device data
// protocol v1 draft. The package owns no network transport, no pairing, no
// iOS UI and no agent loop: it only defines the portable record/command
// shapes and the SQLite transactions that make retries, snapshots and
// cursor recovery safe. See README.md for the implemented boundary.
let package = Package(
    name: "FloeDesktopSync",
    platforms: [
        .macOS(.v15),
        .iOS(.v26)
    ],
    products: [
        .library(name: "FloeDesktopSync", targets: ["FloeDesktopSync"])
    ],
    targets: [
        // Linux Swift does not ship a SQLite3 module in the toolchain SDK.
        // Apple platforms keep using the SDK's SQLite3 module directly; the
        // shim is only selected by the conditional import in SQLiteSupport.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [
                .apt(["libsqlite3-dev"]),
                .brew(["sqlite3"])
            ]
        ),
        .target(
            name: "FloeDesktopSync",
            dependencies: ["CSQLite"]
        ),
        .testTarget(
            name: "FloeDesktopSyncTests",
            dependencies: ["FloeDesktopSync"]
        )
    ],
    swiftLanguageModes: [.v6]
)
