// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FloeAgent",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "FloeCore", targets: ["FloeCore"]),
        .library(name: "FloeModels", targets: ["FloeModels"]),
        .library(name: "FloeProviders", targets: ["FloeProviders"]),
        .library(name: "FloeAgentRuntime", targets: ["FloeAgentRuntime"]),
        .library(name: "FloeTools", targets: ["FloeTools"]),
        .library(name: "FloeSkills", targets: ["FloeSkills"]),
        .library(name: "FloePersistence", targets: ["FloePersistence"]),
        .library(name: "FloeSecurity", targets: ["FloeSecurity"]),
        .library(name: "FloeSyncCore", targets: ["FloeSyncCore"]),
        .library(name: "FloeSync", targets: ["FloeSync"]),
        .library(name: "FloeDocuments", targets: ["FloeDocuments"]),
        .library(name: "FloeImages", targets: ["FloeImages"]),
        .library(name: "FloeSSH", targets: ["FloeSSH"]),
        .library(name: "FloeToolboxSSH", targets: ["FloeToolboxSSH"]),
        .library(name: "FloeToolboxHost", targets: ["FloeToolboxHost"]),
        .library(name: "FloeVNC", targets: ["FloeVNC"]),
        .library(name: "FloeMarkdown", targets: ["FloeMarkdown"]),
        .library(name: "FloeWorkspace", targets: ["FloeWorkspace"]),
        .library(name: "FloeExecution", targets: ["FloeExecution"]),
        .library(name: "FloeIOSAutomation", targets: ["FloeIOSAutomation"]),
        .library(name: "FloeEnvironments", targets: ["FloeEnvironments"]),
        .library(name: "FloePackages", targets: ["FloePackages"]),
        .library(name: "FloeMedia", targets: ["FloeMedia"]),
        .library(name: "FloeWorkbench", targets: ["FloeWorkbench"]),
        .library(name: "FloeNotes", targets: ["FloeNotes"]),
        .library(name: "FloeGit", targets: ["FloeGit"]),
        .library(name: "FloeLocalModelCatalog", targets: ["FloeLocalModelCatalog"]),
        .library(name: "FloeLocalModels", targets: ["FloeLocalModels"]),
        // TEST-ONLY support module (mock adapters, fixtures) for focused
        // tests. Exposed as a product so the App test bundle can host
        // isolated Runtime policy cases through the warm Xcode graph. The
        // App target never depends on it and Release builds do not embed it.
        .library(name: "FloeTestSupport", targets: ["FloeTestSupport"])
    ],
    dependencies: [
        .package(path: "../FloeMacBridge"),
        .package(path: "ThirdParty/WasmKit"),
        .package(path: "Modules/FloeNativeCharts"),
        .package(url: "https://github.com/apple/swift-system", exact: "1.8.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.88.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.6"),
        // NOTE: dev plan pinned apple/swift-nio-ssh 0.11.0 (does not exist).
        // Citadel uses the API-compatible Wellz26 fork 0.3.x. FloeSSH imports
        // NIOSSH directly for strict host-key validation, so this direct pin
        // intentionally matches Citadel's transitive package identity.
        // NOTE: dev plan pinned Citadel 0.11.0 (does not exist). Latest tag
        // 0.9.2 requires swift-crypto <2.1 (conflicts with our 4.1.0 pin);
        // main branch (this revision) supports swift-crypto 3.12.3+.
        // Exact upstream pin and additive patch are verified in ThirdParty/Citadel.
        // Repository-owned source; never modify a shared SwiftPM checkout.
        .package(name: "Citadel", path: "ThirdParty/Citadel"),
        .package(name: "FloeToolbox", path: "Modules/FloeToolbox"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.0"),
        // NOTE: dev plan pinned swift-crypto 4.1.0, but Citadel (main) caps
        // at <4.0.0. 3.15.1 is the newest 3.x. Deviation flagged.
        // Same 3.15.1 source; one dynamic Crypto/Extras runtime for App + tests.
        // See ThirdParty/swift-crypto/FLOE_PATCHES.md and FLOE_UPSTREAM.json.
        .package(path: "ThirdParty/swift-crypto"),
        // Pinned upstream library slice with a synchronized input queue.
        // Provenance and the minimal patch are tracked beside the source.
        .package(path: "ThirdParty/RoyalVNCKit"),
        // ZIPFoundation supplies the bounded archive reader used for local,
        // value-only Office Open XML spreadsheet inspection.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        // SWCompression supplies read-only 7z/RAR container decoding for
        // workspace.archive; archive creation stays zip/tar only.
        .package(url: "https://github.com/tsolomko/SWCompression.git", exact: "4.9.1"),
        // Reviewed local copy of mlx-swift-lm d5d8b290 with Floe's bounded
        // gated-delta prefill fallback. Provenance and the minimal patch live
        // beside the vendored package; no build-cache checkout is patched.
        .package(name: "mlx-swift-lm", path: "ThirdParty/MLXSwiftLM"),
        // Keep the separately qualified MLX array runtime at its exact pin.
        .package(
            url: "https://github.com/ml-explore/mlx-swift.git",
            revision: "ab924c82ead3b970caaa1c0ac11171de23f0305a"
        ),
        // mlx-swift-lm deliberately keeps Hugging Face tokenizers as a
        // consumer-provided integration. Floe downloads model snapshots
        // itself, but still needs the tokenizer implementation to open them.
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.0"
        ),
        // The Xcode app graph resolves its own lock file
        // (FloeAgent.xcodeproj/project.xcworkspace/.../Package.resolved,
        // git-ignored), so in-range transitives drift above the committed
        // host lock and the license inventory then refuses the actual
        // checkouts. These exact pins equal the committed revisions in
        // FloeAgent/Package.resolved (no upgrade): with FloeAgentPackages
        // included by path in the app graph, they constrain both graphs.
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.1"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.6.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "2.4.2"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.0"),
        // Exact SwiftGitX 0.4.0 + libgit2 1.9.2 sources, with the reviewed
        // native libssh2 backend on Apple. See its upstream.lock.json.
        .package(path: "ThirdParty/FloeNativeGit"),
        // Pure Swift SMB2 client. Keep this exact pin: network workspace
        // mounts are audited at install/update time and never enable SMB1.
        .package(
            url: "https://github.com/kishikawakatsumi/SMBClient.git",
            exact: "0.2.1"
        )
    ],
    targets: [
        .binaryTarget(
            name: "LlamaFramework",
            // Official b10581 device/macOS frameworks plus the unmodified
            // llama-ios v1.0.0 (upstream b9754) simulator slice. Device uses
            // b10581 MTMD vision; Simulator is intentionally text-only.
            // The release notes record provenance and both MIT licenses.
            url: "https://github.com/JiangNanGenius/floe-agent/releases/download/llama-runtime-b10581-floe1/llama-b10581-floe1-xcframework.zip",
            checksum: "95e359c6a93b3bc791c5671970ca37f7bdbc9bfae62b55551750186380cea284"
        ),
        .binaryTarget(
            name: "FloeSlirpBinary",
            // libslirp 4.9.7 + trimmed GLib 2.90.1 core + PCRE2 10.46 (JIT
            // disabled) + proxy-libintl 0.5 stubs, merged per-platform static
            // archives with headers. Pinned source, patches, rebuild recipe
            // and every delivered digest: Vendor/FloeSlirp/PROVENANCE.json.
            // Bundled notices and the corresponding-source/relink record ship
            // through the license inventory (Licenses/FloeSlirp-*.txt).
            path: "Vendor/FloeSlirp/FloeSlirp.xcframework"
        ),
        .binaryTarget(
            name: "FloeGPUBinary",
            // Pinned Venus renderer + MoltenVK; static arm64 slices only.
            // Source identities, patch and digests: Vendor/FloeGPU/PROVENANCE.json.
            path: "Vendor/FloeGPU/FloeGPU.xcframework"
        ),
        // MARK: - Cross-platform targets (buildable on macOS host without iOS SDK)

        // Narrow C shim over the SDK's own public `fcntl(F_LOG2PHYS_EXT)`
        // primitive: Swift cannot call the variadic C `fcntl`, so the packed
        // `struct log2phys` in/out is assembled here. No vendored code, no
        // private API and no entitlement; FloeCore is the only consumer
        // (Settings → Data Management measured storage accounting).
        .target(
            name: "CFloeExtentShim",
            dependencies: [],
            path: "Sources/CFloeExtentShim",
            publicHeadersPath: "include"
        ),

        // Public Darwin wrappers: punch holes, snapshot bounded ACL metadata,
        // and restore the job-owned stage birthtime with fsetattrlist.
        // No private API, no vendored code, no entitlement.
        .target(
            name: "CFloeSparseRewriteShim",
            dependencies: [],
            path: "Sources/CFloeSparseRewriteShim",
            publicHeadersPath: "include"
        ),

        .target(
            name: "FloeCore",
            dependencies: [
                "CFloeExtentShim",
                "CFloeSparseRewriteShim",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeModels",
            dependencies: [
                "FloeCore",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeModels",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeProviders",
            dependencies: ["FloeCore", "FloeModels"],
            path: "Sources/FloeProviders",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeLlamaVisionShim",
            dependencies: [],
            path: "Sources/FloeLlamaVisionShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FloeVirtualGPU",
            dependencies: ["FloeGPUBinary"],
            path: "ThirdParty/FloeVirtualGPU",
            exclude: ["README.md", "patches", "LICENSES"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("_POSIX_C_SOURCE", to: "200809L"),
                .define("_DARWIN_C_SOURCE"),
                .unsafeFlags(["-std=c11", "-O2", "-fvisibility=hidden"])
            ],
            linkerSettings: [
                .linkedLibrary("c++"), .linkedLibrary("objc"), .linkedLibrary("m"),
                .linkedFramework("Metal"), .linkedFramework("IOSurface"),
                .linkedFramework("QuartzCore"), .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"), .linkedFramework("CoreFoundation"),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        ),
        // Resident ARM64 interpreter. GPU and online-memory devices are
        // enabled only for guest images declaring the corresponding drivers.
        .target(
            name: "FloeARM64Engine",
            dependencies: ["FloeSlirpBinary", "FloeVirtualGPU"],
            path: "ThirdParty/ARM64EMU",
            exclude: ["Source", "Bridge", "Tools", "PROVENANCE.json"],
            sources: ["Sources"],
            resources: [.copy("PrivacyInfo.xcprivacy")],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Source/src"),
                .headerSearchPath("Bridge"),
                .define("_POSIX_C_SOURCE", to: "200809L"),
                .define("_DARWIN_C_SOURCE"),
                // Vendored static stack (FloeSlirpBinary): the merged archive
                // embeds the GLib core and PCRE2; consumers include
                // <slirp/libslirp.h> only, and these defines match the
                // static-archive build settings recorded in
                // Vendor/FloeSlirp/PROVENANCE.json.
                .define("G_INTL_STATIC_COMPILATION"),
                .define("PCRE2_STATIC"),
                .define("SLIRP_FLOE_HOST_HOOKS"),
                .define("VN_ADVERTISE_RX_GSO", to: "0"),
                .unsafeFlags(["-std=c11", "-UNDEBUG", "-fno-math-errno", "-fvisibility=hidden"]),
                // Interpreter throughput is part of the runtime in Debug
                // too; keep assertions and line info while optimizing the C core.
                .unsafeFlags(["-O2"])
            ],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.iOS, .macOS])),
                .linkedLibrary("m"),
                .linkedLibrary("resolv", .when(platforms: [.iOS, .macOS])),
                // Required by the FloeSlirp static archives (glib charset glue
                // uses iconv; its macOS-special-dir objects use the public
                // ObjC/Foundation/CoreFoundation surfaces). AppKit/Carbon are
                // referenced only by the host macOS archive.
                .linkedLibrary("iconv"),
                .linkedLibrary("objc"),
                .linkedFramework("Foundation", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("Carbon", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "FloeLocalModelCatalog",
            dependencies: ["FloeCore"],
            path: "Sources/FloeLocalModelCatalog",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FloeLocalModels",
            dependencies: [
                "FloeCore", "FloeModels", "FloeProviders", "FloeLocalModelCatalog",
                // Kept in source for compatibility and possible future
                // fallback, but the public v1.4.19 catalog is MLX-only.
                "LlamaFramework", "FloeLlamaVisionShim",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/FloeLocalModels",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .target(
            name: "FloeAgentRuntime",
            dependencies: [
                "FloeCore", "FloeModels", "FloeProviders", "FloeTools",
                "FloePersistence", "FloeSecurity",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeAgentRuntime",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeTools",
            dependencies: [
                "FloeCore", "FloeModels",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeTools",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeIOSAutomation",
            dependencies: ["FloeCore"],
            path: "Sources/FloeIOSAutomation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSkills",
            dependencies: [
                "FloeTools",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeSkills",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeExecution",
            dependencies: [
                .product(name: "FloeNativeChartsCore", package: "FloeNativeCharts"),
                .product(name: "FloeMacBridgeProtocol", package: "FloeMacBridge"),
                .product(name: "FloeWasmRuntime", package: "WasmKit"),
                .product(name: "SystemPackage", package: "swift-system"),
                "FloeCore", "FloeTools", "FloeSSH", "FloeWorkspace", "FloeSecurity",
                .product(name: "FloeToolboxDiagnostics", package: "FloeToolbox"),
                // Interpreted shared ARM64 Linux, without a host fallback.
                "FloeARM64Engine",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeExecution",
            resources: [.copy("Resources/RemoteAgent"), .process("Resources/CapabilityCatalog.json"), .process("Resources/ToolCapabilityCatalog.json"), .process("Resources/PresentationChartExamples.json"), .process("Resources/deb_extract.py"), .process("Resources/LinuxPackageSources.json"), .process("Resources/linux_package_sources.py")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloePersistence",
            dependencies: [
                "FloeCore",
                "FloeModels",
                "FloeSecurity",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/FloePersistence",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSecurity",
            dependencies: [
                "FloeCore",
                "FloeModels",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeSecurity",
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSyncCore",
            dependencies: ["FloeCore"],
            path: "Sources/FloeSyncCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        // MARK: - iOS-only targets (require full Xcode, not buildable on this host)

        .target(
            name: "FloeSync",
            dependencies: ["FloeCore", "FloeModels", "FloeSyncCore", "FloePersistence", "FloeSecurity"],
            path: "Sources/FloeSync",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeDocuments",
            dependencies: [
                "FloeCore",
                "FloeTools",
                "FloeWorkspace",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeDocuments",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeImages",
            dependencies: [
                "FloeCore",
                "FloeTools",
                "FloeWorkspace",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeImages",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeSSH",
            dependencies: [
                "FloeCore",
                "FloeSecurity",
                "FloePersistence",
                "FloeTools",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeSSH",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeToolboxSSH",
            dependencies: [
                "FloeSSH",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxRemoteFiles", package: "FloeToolbox"),
                .product(name: "FloeToolboxFileTransports", package: "FloeToolbox"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
            ],
            path: "Sources/FloeToolboxSSH",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeToolboxHost",
            dependencies: [
                "FloeCore", "FloeTools", "FloeExecution", "FloeWorkspace",
                .product(name: "FloeToolboxCore", package: "FloeToolbox"),
                .product(name: "FloeToolboxClients", package: "FloeToolbox"),
                .product(name: "FloeToolboxRemoteFiles", package: "FloeToolbox"),
                .product(name: "FloeToolboxFileTransports", package: "FloeToolbox")
            ],
            path: "Modules/FloeToolbox/Integration/FloeToolboxHost",
            exclude: ["SSHFileBridge.swift"],
            sources: ["NativeToolboxTools.swift", "BluetoothBridge.swift", "WorkspaceMountBridge.swift"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),

        .target(
            name: "FloeVNC",
            dependencies: [
                "FloeCore",
                "FloePersistence",
                "FloeSecurity",
                "FloeTools",
                .product(name: "RoyalVNCKit", package: "RoyalVNCKit"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeVNC",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeMarkdown",
            dependencies: ["FloeCore"],
            path: "Sources/FloeMarkdown",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        // Narrow C shim over the SDK's own libbz2 streaming API (iOS and
        // macOS both ship `usr/lib/libbz2.tbd`). No vendored bzip2 is added;
        // FloeWorkspace is the only consumer, for bounded bz2/tbz2 decode and
        // streaming encode.
        .target(
            name: "CFloeArchive",
            dependencies: [],
            path: "Sources/CFloeArchive",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("bz2")]
        ),

        .target(
            name: "FloeWorkspace",
            dependencies: [
                "FloeCore",
                "FloeModels",
                "FloeTools",
                "CFloeArchive",
                .product(name: "SMBClient", package: "SMBClient"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "SWCompression", package: "SWCompression"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeWorkspace",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeEnvironments",
            dependencies: ["FloeCore", "FloeTools"],
            path: "Sources/FloeEnvironments",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloePackages",
            dependencies: [
                "FloeCore", "FloeTools", "FloeEnvironments",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SWCompression", package: "SWCompression")
            ],
            path: "Sources/FloePackages",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeNotes",
            dependencies: ["FloeCore", .product(name: "GRDB", package: "GRDB.swift"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/FloeNotes",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .target(
            name: "FloeMedia",
            dependencies: ["FloeCore", "FloeTools"],
            path: "Sources/FloeMedia",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeGit",
            dependencies: [
                "FloeCore", "FloeModels", "FloeTools", "FloeSecurity",
                .product(name: "SwiftGitX", package: "FloeNativeGit"),
                .product(name: "libgit2", package: "FloeNativeGit"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeGit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        .target(
            name: "FloeWorkbench",
            dependencies: [
                "FloeCore", "FloeTools",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/FloeWorkbench",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),

        // MARK: - Test targets

        .target(
            name: "FloeTestSupport",
            dependencies: ["FloeCore", "FloeModels"],
            path: "Tests/FloeTestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeCoreTests",
            dependencies: ["FloeCore", "FloeTestSupport"],
            path: "Tests/FloeCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeModelsTests",
            dependencies: ["FloeModels", "FloeTestSupport"],
            path: "Tests/FloeModelsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeProvidersTests",
            dependencies: ["FloeProviders", "FloeTestSupport", "FloeTools"],
            path: "Tests/FloeProvidersTests",
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeAgentRuntimeTests",
            dependencies: ["FloeAgentRuntime", "FloePersistence", "FloeTestSupport"],
            path: "Tests/FloeAgentRuntimeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeToolsTests",
            dependencies: ["FloeTools", "FloeAgentRuntime", "FloeExecution", "FloeTestSupport"],
            path: "Tests/FloeToolsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeSkillsTests",
            dependencies: ["FloeSkills", "FloeTools", .product(name: "ZIPFoundation", package: "ZIPFoundation"), .product(name: "Crypto", package: "swift-crypto")],
            path: "Tests/FloeSkillsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloePersistenceTests",
            dependencies: ["FloePersistence", "FloeTestSupport"],
            path: "Tests/FloePersistenceTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeIOSAutomationTests",
            dependencies: ["FloeIOSAutomation", "FloeCore"],
            path: "Tests/FloeIOSAutomationTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeSkillEnvironmentTests",
            dependencies: ["FloeExecution", "FloeTools", "FloeCore"],
            path: "Tests/FloeSkillEnvironmentTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeSyncTests",
            dependencies: ["FloeSync", "FloePersistence"],
            path: "Tests/FloeSyncTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
                .enableUpcomingFeature("InferSendableFromCaptures")
            ]
        ),

        .testTarget(
            name: "FloeSecurityTests",
            dependencies: ["FloeSecurity", "FloeTestSupport"],
            path: "Tests/FloeSecurityTests",
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeDocumentsTests",
            dependencies: [
                "FloeDocuments",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Tests/FloeDocumentsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeSSHTests",
            dependencies: ["FloeSSH"],
            path: "Tests/FloeSSHTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeVNCTests",
            dependencies: ["FloeVNC", "FloeTools", "FloeCore", .product(name: "RoyalVNCKit", package: "RoyalVNCKit")],
            path: "Tests/FloeVNCTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeMarkdownTests",
            dependencies: ["FloeMarkdown"],
            path: "Tests/FloeMarkdownTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeImagesTests",
            dependencies: ["FloeImages"],
            path: "Tests/FloeImagesTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeWorkspaceTests",
            dependencies: ["FloeWorkspace", "FloeTools", "FloeModels", "FloeTestSupport", "CFloeArchive"],
            path: "Tests/FloeWorkspaceTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeGitTests",
            dependencies: ["FloeGit", "FloeTools", "FloeModels"],
            path: "Tests/FloeGitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeExecutionTests",
            dependencies: [
                "FloeExecution", "FloeCore", "FloeTools", "FloeModels",
                "FloeAgentRuntime", "FloeSSH", "FloePersistence", "FloeTestSupport",
                .product(name: "FloeToolboxDiagnostics", package: "FloeToolbox"),
                .product(name: "WAT", package: "WasmKit"), .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Tests/FloeExecutionTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeMacBridgeTests",
            dependencies: ["FloeExecution"],
            path: "Tests/FloeMacBridgeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloePackagesTests",
            dependencies: [
                "FloePackages", "FloeCore", "FloeTools", "FloeEnvironments"
            ],
            path: "Tests/FloePackagesTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeLocalModelsTests",
            dependencies: [
                "FloeLocalModelCatalog", "FloeLocalModels", "FloeProviders",
                "FloeModels", "FloeCore", "FloeAgentRuntime", "FloeExecution"
            ],
            path: "Tests/FloeLocalModelsTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "FloeNotesTests",
            dependencies: ["FloeNotes"],
            path: "Tests/FloeNotesTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        .testTarget(
            name: "FloeWorkbenchTests",
            dependencies: ["FloeWorkbench", "FloeTools", "FloeCore"],
            path: "Tests/FloeWorkbenchTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
