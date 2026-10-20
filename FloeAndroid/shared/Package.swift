// swift-tools-version: 6.4
import PackageDescription

// Production G02 shared-core overlay (audit job-dee5658543974844 recipes
// promoted per implementation-packages G02-P0/P1). Per-file relative source
// links reuse the ORIGINAL FloeAgent business/runtime/persistence layers
// without resolving iOS-only binary dependencies; only the documented
// Android mirror patches exist as narrow copied overlays (see PROVENANCE.md).
// KeychainStore.swift is EXCLUDED entirely: its non-Security branch is a
// process-wide RAM store, forbidden on Android (fail-closed directive).
let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "FloeAndroidCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "FloeAndroidCore", type: .dynamic, targets: ["FloeAndroidCore"])],
    dependencies: [
        // Pinned EXACT revision (immutable commit, no floating version or
        // tag lookup at build time): 95ba0316a9b733e92bb6b071255ff46263bbe7dc
        // (3.15.1, declares Platform.android). Reproducible from a fresh
        // checkout via SwiftPM + Package.resolved (Main reproducibility
        // directive 2026-10-18; replaces the audit's DerivedData path
        // symlink so no product source points at personal cache paths).
        .package(url: "https://github.com/apple/swift-crypto.git",
                 revision: "95ba0316a9b733e92bb6b071255ff46263bbe7dc"),
    ],
    targets: [
        // Original value layer (69 of 75 files are links; the 6 patched
        // copies carry the documented POSIX-visibility / CFBoolean / APFS
        // islands, production-corrected for exact Bool semantics).
        .target(name: "FloeCore", dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .target(name: "FloeModels", dependencies: [
            "FloeCore",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // Android/Linux incremental byte-transport seam (G02-P3). A separate
        // small target — NOT a Core/Providers/Tools framework replacement —
        // because FloeProviders and FloeTools are SIBLING dependents of the
        // original value layers; hosting the shared seam in either would add
        // a Tools→Providers (or reverse) edge. Pure Foundation plumbing;
        // Apple platforms never take this code path (bytes(for:) stays).
        .target(name: "FloeTransport", dependencies: [], swiftSettings: strictSettings),
        .target(name: "FloeProviders", dependencies: [
            "FloeCore", "FloeModels", "FloeTransport",
        ], swiftSettings: strictSettings),
        // Android fail-closed policy: KeychainStore.swift is not linked at
        // all (the audit used exclude: on a linked copy; production removes
        // the file from the overlay so no RAM stub can ever compile).
        .target(name: "FloeSecurity", dependencies: [
            "FloeCore", "FloeModels",
            .product(name: "Crypto", package: "swift-crypto"),
        ], resources: [.copy("Resources")], swiftSettings: strictSettings),
        .target(name: "FloeTools", dependencies: [
            "FloeCore", "FloeModels", "FloeTransport",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // D1 minimal web.search/web.fetch closure (Main decisions
        // 2026-10-18; runtime-facade-contract D1/RB-6): exactly the five
        // ORIGINAL FloeExecution files — WebFetchTool, WebSearchTool,
        // WebRetrievalModels as unmodified per-file links; HTTPRequestService
        // and WebSearchService as narrow documented platform mirrors (see
        // PROVENANCE.md). NOT the whole FloeExecution port: no tool
        // registration, no facade/service binding yet. The real future
        // facade resolver supplies SQLiteSettingsStore + the secure gateway
        // by credentialAccount; nothing here fabricates configuration or
        // credential fallbacks. Sessions ride the qualified
        // FloeTransport StreamingTransport seam (job-ca18980891c043b5).
        .target(name: "FloeAndroidWebTools", dependencies: [
            "FloeCore", "FloeTools", "FloeTransport",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // Android-safe manifest mirror of ZIPFoundation 0.9.20 (rev
        // 22787ffb59de99e5dc1fbfe80b19c97a904ad48d): the upstream
        // Package.swift picks its zlib binding with a host-evaluated
        // #if canImport(Compression), so an android28 cross build sees no
        // CZlib target. Vendored shim keeps the same upstream Swift sources
        // with documented Android import-visibility patches.
        .target(name: "CZLib", publicHeadersPath: "."),
        .target(name: "ZIPFoundation", dependencies: ["CZLib"],
                // Upstream ships swiftLanguageVersions [.v4, .v5]; the mirror
                // must not be forced into Swift 6 strict-concurrency rules.
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "FloeSkills", dependencies: [
            "FloeTools",
            "ZIPFoundation",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // Persistence authority: vendored SQLite 3.54.1 amalgamation (NDK
        // ships no sqlite3 stub) + GRDB v7.8.0 (rev 18497b68fdbb3a09528d260a
        // 0a0e1e7e61c8c53d) with exactly 9 documented platform-condition
        // patch sites treating Android like corelibs Linux.
        .target(name: "GRDBSQLite", publicHeadersPath: ".", cSettings: [
            .define("SQLITE_ENABLE_FTS5", to: "1"),
            .define("SQLITE_THREADSAFE", to: "2"),
            // Production correction #4 over the audit recipe: GRDB's
            // WALSnapshot references sqlite3_snapshot_* and the probe's
            // dynamic Android link left those symbols UNDEFINED (latent
            // device dlopen/call landmine); Apple's system SQLite exports
            // them. Compile the vendored amalgamation with snapshot support
            // so the actual closure resolves on ANDROID AND HOST alike.
            .define("SQLITE_ENABLE_SNAPSHOT", to: "1"),
        ]),
        .target(name: "GRDB", dependencies: ["GRDBSQLite"],
                swiftSettings: [.define("SQLITE_ENABLE_FTS5")]),
        .target(name: "FloePersistence", dependencies: [
            "FloeCore", "FloeModels", "FloeSecurity", "GRDB",
        ], swiftSettings: strictSettings),
        // CURRENT runtime authority (40 files: ConversationRunService,
        // AgentRuntime, HarnessEvent/Channel, DelegateTool registry,
        // ChildRunStore, goals/plans/checkpoints) — compiled shared layer,
        // no fake alternate loop and no legacy exec aliases.
        .target(name: "FloeAgentRuntime", dependencies: [
            "FloeCore", "FloeModels", "FloeProviders", "FloeTools",
            "FloePersistence", "FloeSecurity", "GRDB",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // Product bridge: v1 frozen operations + append-only v2 envelope
        // seam + fail-closed credential backend + real dependency anchors.
        .target(name: "FloeAndroidCore", dependencies: [
            "FloeCore", "FloeModels", "FloeProviders", "FloeSecurity",
            "FloeTools", "FloeSkills", "FloePersistence", "FloeAgentRuntime",
            // D1 web closure: included in the actual native .so so the
            // qualified original tools/service link before the facade
            // registers them (dependency only; NO service registration here).
            "FloeAndroidWebTools",
            // G02 transport startup admission: the REAL production
            // `StreamingTransport.makeSession` factory initialization fact is
            // evaluated inside the composition before the immutable RunContext
            // snapshot (MAIN_PRODUCT_TRANSPORT_STARTUP_ADMISSION_DECISION_
            // 20261020). FloeTransport is already linked into the product .so
            // through FloeProviders/FloeTools; this is a direct dependency
            // edge only, no second transport.
            "FloeTransport",
            // QualificationSeam.swift exercises the real sqlite3_snapshot_*
            // C APIs directly (import GRDBSQLite); the amalgamation itself was
            // already compiled into the product library through GRDB.
            "GRDB", "GRDBSQLite",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .testTarget(name: "FloeAndroidCoreTests", dependencies: [
            "FloeAndroidCore", "FloeCore", "FloeModels", "FloePersistence", "GRDB",
            // G02-P3 transport suites: the REAL incremental seam + provider
            // pump/MCP collect bodies run on the host against synthetic
            // loopback fixtures (compiled identically to the Android build).
            "FloeTransport", "FloeProviders", "FloeTools",
            // D1 web closure suites: the Android streaming/collect bodies +
            // session constructions above run against the same loopback
            // fixtures; original tool/service semantics are tested directly.
            "FloeAndroidWebTools",
        ], swiftSettings: strictSettings)
    ]
)
