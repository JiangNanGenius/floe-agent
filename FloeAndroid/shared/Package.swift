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
    products: [
        .library(name: "FloeAndroidCore", type: .dynamic, targets: ["FloeAndroidCore"]),
        .library(name: "FloeAndroidLinuxAuthority", type: .dynamic, targets: ["FloeAndroidLinuxAuthority"]),
    ],
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
        // G03-R1 environment authority (job-d15dbb99ae374286): the ORIGINAL
        // FloeEnvironments module, ported per the FloeAndroidWebTools
        // provenance pattern — nine per-file relative links reuse the iOS
        // authority byte-for-byte; `ContainerRecord`, `EnvironmentRoots` and
        // `EnvironmentRegistry` are narrow documented Android mirrors (see
        // PROVENANCE.md G03-R1 section); `LinuxExecutionLeaseDescriptor.swift`
        // is Android-owned. Depends on FloeCore+FloeTools only, exactly like
        // FloeAgent/Package.swift. NO alternate registry/executor, NO routing
        // registration here: Main's composition wires ToolEnvironmentRouting
        // and supplies the explicit trusted root + selected backend.
        .target(name: "FloeEnvironments", dependencies: [
            "FloeCore", "FloeTools",
        ], swiftSettings: strictSettings),
        .target(name: "FloeAndroidLinuxAuthority", dependencies: [
            "FloeEnvironments", "FloeCore", "FloeTools",
        ], swiftSettings: strictSettings),
        .target(name: "FloeAndroidShellTools", dependencies: [
            "FloeCore", "FloeTools", "FloeSecurity",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .target(name: "FloeAndroidWorkspaceTools", dependencies: [
            "FloeCore", "FloeTools",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // G04 file/text authority: selected original FloeWorkspace services
        // plus narrow documented Android adapters. Rendering, SAF transport
        // and task-domain binding remain separate consumers of this module.
        // G04 native Git engine: reviewed pinned source overlay, Main D2.
        // pinned overlay of ibrahimcetin/libgit2 52287b09 (tag 1.9.2),
        // ibrahimcetin/SwiftGitX fcfb71e3 (tag 0.4.0) and Mbed-TLS 3.6.7
        // (sha256 a7e8bcbe…d11f6, official release body). All compiled C/H are
        // byte-identical upstream exports (Vendor/Git/VENDOR_FILE_HASHES.sha256);
        // the ONLY non-upstream bytes are the documented
        // mbedtls/floe-config/floe_android_mbedtls_config.h TLS-1.3 hunk.
        // Upstream manifests cannot be consumed for android28: libgit2's own
        // Package.swift selects Apple vs non-Apple settings with a HOST-side
        // `#if os(macOS)` (a macOS-driven Android cross build would compile
        // SecureTransport/CommonCrypto for Bionic) and its non-Apple branch
        // assumes glibc + runtime-dlopen OpenSSL (Android exposes no public
        // libssl/libcrypto). This overlay keeps the identical Apple define set
        // for host qualification runs and adds an explicit Android set with
        // libgit2's supported mbedTLS TLS backend (TLS 1.2 ceiling per the
        // config patch), bundled zlib/regex/llhttp/xdiff, BUILTIN hashes,
        // pthreads and getentropy (API 28+). SSH transport and NTLM auth are
        // OFF on both overlay platforms (documented in Vendor/Git/README.md:
        // FloeGit's own product contract restricts remotes to HTTPS
        // github.com, and the ntlmclient backend dispatch in crypt.h
        // #errors without one of OpenSSL/CommonCrypto/mbedTLS, which the
        // static SwiftPM source list cannot condition; iOS production keeps
        // the upstream package with NTLM intact).
        .target(
            name: "MbedTLS",
            dependencies: [],
            path: "Vendor/Git/mbedtls",
            sources: ["library"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("library"),
                .headerSearchPath("floe-config"),
                .define("MBEDTLS_CONFIG_FILE",
                        to: "\"floe_android_mbedtls_config.h\""),
            ]
        ),
        .target(
            name: "libgit2",
            dependencies: [
                .target(name: "MbedTLS", condition: .when(platforms: [.android])),
            ],
            path: "Vendor/Git/libgit2",
            exclude: [
                "deps/llhttp/LICENSE-MIT",
                "deps/pcre/COPYING",
                "deps/pcre/LICENCE",
                "deps/pcre/cmake",
                "deps/pcre/config.h.in",
                "deps/zlib/LICENSE",
                // FLOE-OVERLAY 20261024-1 (lane job-7320d971f5df43c0,
                // Main-approved): upstream common_crypto.c includes
                // <CommonCrypto/CommonDigest.h> BEFORE the
                // GIT_SHA1/SHA256_COMMON_CRYPTO backend guards (upstream
                // CMake excluded this TU on non-Apple; a static SwiftPM
                // source list cannot, and host-side #if os(macOS) source
                // selection is forbidden for the android28 cross build).
                // The gated wrapper Vendor/Git/libgit2/src/util/hash/
                // floe_common_crypto.c #includes the ORIGINAL file verbatim
                // only when a CommonCrypto backend macro is defined (Apple
                // host cohort behavior unchanged) and compiles empty on
                // Android (BUILTIN hashes). No supported backend is
                // narrowed; no upstream bytes edited. See
                // Vendor/Git/README.md + PINS.json.gatedOverlayTU.
                "src/util/hash/common_crypto.c",
                // FLOE-OVERLAY 20261024-2 (lane job-6975418b406c4035, same
                // Main-approved gated-wrapper pattern): upstream CMake
                // compiles collisiondetect.c / builtin.c ONLY when the
                // BUILTIN SHA1/SHA256 backends are selected (Android).
                // Their headers define the git_hash_*_ctx structs and their
                // TUs define the git_hash_* functions unconditionally, so
                // static compilation collides with the CommonCrypto backend
                // on Apple hosts (redefinition + duplicate symbols). The
                // gated wrappers src/util/hash/floe_collisiondetect.c and
                // floe_builtin.c #include the ORIGINAL files verbatim under
                // the matching BUILTIN macro and compile empty otherwise —
                // Android inputs stay byte-equivalent code paths, Apple
                // matches the upstream Apple source set. No backend is
                // narrowed; no upstream bytes edited. See
                // Vendor/Git/PINS.json + FLOE_OVERLAY_HASHES.sha256.
                "src/util/hash/collisiondetect.c",
                "src/util/hash/builtin.c",
                "src/util/hash/win32.c",
                "src/util/hash/win32.h",
                "src/util/win32",
            ],
            sources: [
                "deps/llhttp", "deps/pcre", "deps/xdiff", "deps/zlib",
                "src/libgit2", "src/util",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // Search paths shared by both platform families (the two
                // builtin-hash folders are compiled inert on Apple; keeping
                // the paths unconditional avoids platform-dependent lists).
                .headerSearchPath("deps/llhttp"),
                .headerSearchPath("deps/pcre"),
                .headerSearchPath("deps/xdiff"),
                .headerSearchPath("deps/zlib"),
                .headerSearchPath("src/libgit2"),
                .headerSearchPath("src/util"),
                .headerSearchPath("src/util/hash/sha1dc"),
                .headerSearchPath("src/util/hash/rfc6234"),
                // Android: mbedTLS headers come from the vendored sibling
                // (relative to this target path), plus the overlay config.
                .headerSearchPath("../mbedtls/include"),
                .headerSearchPath("../mbedtls/floe-config"),
                // ── common configuration (matches the upstream manifest) ──
                .define("LIBGIT2_NO_FEATURES_H"),
                .define("GIT_THREADS", to: "1"),
                .define("GIT_THREADS_PTHREADS", to: "1"),
                .define("GIT_ARCH_64", to: "1"),
                .define("GIT_REGEX_BUILTIN", to: "1"),
                .define("SUPPORT_PCRE8", to: "1"),
                .define("HAVE_STDINT_H", to: "1"),
                .define("HAVE_INTTYPES_H", to: "1"),
                .define("HAVE_MEMMOVE", to: "1"),
                .define("HAVE_STRERROR", to: "1"),
                .define("LINK_SIZE", to: "2"),
                .define("PARENS_NEST_LIMIT", to: "250"),
                .define("MATCH_LIMIT", to: "10000000"),
                .define("MATCH_LIMIT_RECURSION", to: "10000000"),
                .define("NEWLINE", to: "10"),
                .define("NO_RECURSE", to: "1"),
                .define("POSIX_MALLOC_THRESHOLD", to: "10"),
                .define("BSR_ANYCRLF", to: "0"),
                .define("MAX_NAME_SIZE", to: "32"),
                .define("MAX_NAME_COUNT", to: "10000"),
                .define("GIT_HTTPS", to: "1"),
                .define("GIT_HTTPPARSER_BUILTIN", to: "1"),
                .define("GIT_IO_POLL", to: "1"),
                .define("GIT_NSEC", to: "1"),
                .define("GIT_FUTIMENS", to: "1"),
                // ── Apple hosts (macOS qualification cohort): byte-equal to
                // the upstream Apple branch so host runs mirror iOS ──
                .define("GIT_QSORT_BSD", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .define("GIT_HTTPS_SECURETRANSPORT", to: "1",
                        .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .define("GIT_SHA1_COMMON_CRYPTO", to: "1",
                        .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .define("GIT_SHA256_COMMON_CRYPTO", to: "1",
                        .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .define("GIT_NSEC_MTIMESPEC", to: "1",
                        .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .define("GIT_I18N", to: "1",
                        .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .define("GIT_I18N_ICONV", to: "1",
                        .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .define("GIT_NO_PROCESS_SPAWN", .when(platforms: [.tvOS, .watchOS])),
                // ── Android (NDK30 clang, aarch64-unknown-linux-android28) ──
                // No GIT_QSORT_* define: Bionic has neither BSD nor GNU
                // qsort_r; libgit2's portable fallback (src/util/util.c)
                // compiles when none is defined. getentropy/futimens/poll/
                // st_mtim exist at API 28 (Bionic).
                .define("_GNU_SOURCE", .when(platforms: [.android])),
                .define("GIT_HTTPS_MBEDTLS", to: "1", .when(platforms: [.android])),
                .define("GIT_SHA1_BUILTIN", to: "1", .when(platforms: [.android])),
                .define("GIT_SHA256_BUILTIN", to: "1", .when(platforms: [.android])),
                .define("SHA1DC_NO_STANDARD_INCLUDES", to: "1", .when(platforms: [.android])),
                .define("SHA1DC_CUSTOM_INCLUDE_SHA1_C", to: "\"git2_util.h\"", .when(platforms: [.android])),
                .define("SHA1DC_CUSTOM_INCLUDE_UBC_CHECK_C", to: "\"git2_util.h\"", .when(platforms: [.android])),
                .define("GIT_NSEC_MTIM", to: "1", .when(platforms: [.android])),
                .define("GIT_RAND_GETENTROPY", to: "1", .when(platforms: [.android])),
                // Same overlay config for consumers that embed mbedtls
                // structs (streams/mbedtls.c holds global session structs:
                // the config MUST match the MbedTLS target byte-for-byte).
                .define("MBEDTLS_CONFIG_FILE", to: "\"floe_android_mbedtls_config.h\"",
                        .when(platforms: [.android])),
                // Android remote Git installs its verified current platform
                // bundle per runtime operation; no fixed CA-directory fallback.
            ],
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .linkedLibrary("iconv", .when(platforms: [.macOS, .iOS])),
                // Android needs NOTHING extra: bundled zlib is compiled,
                // pthread/dl symbols live in Bionic libc, and the product
                // .so links everything statically (no host/library paths).
            ]
        ),
        .target(
            name: "SwiftGitX",
            dependencies: ["libgit2"],
            path: "Vendor/Git/swiftgitx/Sources/SwiftGitX",
            swiftSettings: strictSettings
        ),
        .target(name: "FloeGitShim", dependencies: ["libgit2"],
            path: "Vendor/Git/floe-shim", publicHeadersPath: "include"),
        .target(name: "FloeGit", dependencies: [
            "FloeCore", "FloeModels", "FloeTools", "FloeTransport",
            "SwiftGitX", "libgit2", "FloeGitShim",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // G04 archive/network: pinned portable source-only dependencies.
        // Exact C object sets/configs are exported in Vendor/*/floe recipes.
        .target(name: "BitByteData", path: "Vendor/Archive/BitByteData-2.1.0/Sources",
                exclude: ["PrivacyInfo.xcprivacy"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "SWCompression", dependencies: ["BitByteData"],
                path: "Vendor/Archive/SWCompression-4.9.1/Sources",
                exclude: ["PrivacyInfo.xcprivacy", "swcomp"],
                sources: ["Common", "7-Zip", "BZip2", "Deflate", "GZip", "LZ4", "LZMA", "LZMA2", "TAR", "XZ", "ZIP", "Zlib"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CBZip2", path: "Vendor/Archive/bzip2-1.0.8",
                exclude: ["LICENSE", "README", "CHANGES", "SOURCE-PIN.json"],
                sources: ["blocksort.c", "bzlib.c", "compress.c", "crctable.c",
                          "decompress.c", "huffman.c", "randtable.c"],
                publicHeadersPath: "."),
        .target(
            name: "CLzma",
            path: "Vendor/Archive/xz-5.8.1",
            sources: [
                "src/common/tuklib_physmem.c",
                "src/liblzma/check/check.c",
                "src/liblzma/check/crc32_fast.c",
                "src/liblzma/check/crc64_fast.c",
                "src/liblzma/check/sha256.c",
                "src/liblzma/common/alone_decoder.c",
                "src/liblzma/common/alone_encoder.c",
                "src/liblzma/common/auto_decoder.c",
                "src/liblzma/common/block_buffer_decoder.c",
                "src/liblzma/common/block_buffer_encoder.c",
                "src/liblzma/common/block_decoder.c",
                "src/liblzma/common/block_encoder.c",
                "src/liblzma/common/block_header_decoder.c",
                "src/liblzma/common/block_header_encoder.c",
                "src/liblzma/common/block_util.c",
                "src/liblzma/common/common.c",
                "src/liblzma/common/easy_buffer_encoder.c",
                "src/liblzma/common/easy_decoder_memusage.c",
                "src/liblzma/common/easy_encoder.c",
                "src/liblzma/common/easy_encoder_memusage.c",
                "src/liblzma/common/easy_preset.c",
                "src/liblzma/common/file_info.c",
                "src/liblzma/common/filter_buffer_decoder.c",
                "src/liblzma/common/filter_buffer_encoder.c",
                "src/liblzma/common/filter_common.c",
                "src/liblzma/common/filter_decoder.c",
                "src/liblzma/common/filter_encoder.c",
                "src/liblzma/common/filter_flags_decoder.c",
                "src/liblzma/common/filter_flags_encoder.c",
                "src/liblzma/common/hardware_physmem.c",
                "src/liblzma/common/index.c",
                "src/liblzma/common/index_decoder.c",
                "src/liblzma/common/index_encoder.c",
                "src/liblzma/common/index_hash.c",
                "src/liblzma/common/lzip_decoder.c",
                "src/liblzma/common/microlzma_decoder.c",
                "src/liblzma/common/microlzma_encoder.c",
                "src/liblzma/common/stream_buffer_decoder.c",
                "src/liblzma/common/stream_buffer_encoder.c",
                "src/liblzma/common/stream_decoder.c",
                "src/liblzma/common/stream_encoder.c",
                "src/liblzma/common/stream_flags_common.c",
                "src/liblzma/common/stream_flags_decoder.c",
                "src/liblzma/common/stream_flags_encoder.c",
                "src/liblzma/common/string_conversion.c",
                "src/liblzma/common/vli_decoder.c",
                "src/liblzma/common/vli_encoder.c",
                "src/liblzma/common/vli_size.c",
                "src/liblzma/delta/delta_common.c",
                "src/liblzma/delta/delta_decoder.c",
                "src/liblzma/delta/delta_encoder.c",
                "src/liblzma/lz/lz_decoder.c",
                "src/liblzma/lz/lz_encoder.c",
                "src/liblzma/lz/lz_encoder_mf.c",
                "src/liblzma/lzma/fastpos_table.c",
                "src/liblzma/lzma/lzma2_decoder.c",
                "src/liblzma/lzma/lzma2_encoder.c",
                "src/liblzma/lzma/lzma_decoder.c",
                "src/liblzma/lzma/lzma_encoder.c",
                "src/liblzma/lzma/lzma_encoder_optimum_fast.c",
                "src/liblzma/lzma/lzma_encoder_optimum_normal.c",
                "src/liblzma/lzma/lzma_encoder_presets.c",
                "src/liblzma/rangecoder/price_table.c",
                "src/liblzma/simple/arm.c",
                "src/liblzma/simple/arm64.c",
                "src/liblzma/simple/armthumb.c",
                "src/liblzma/simple/ia64.c",
                "src/liblzma/simple/powerpc.c",
                "src/liblzma/simple/riscv.c",
                "src/liblzma/simple/simple_coder.c",
                "src/liblzma/simple/simple_decoder.c",
                "src/liblzma/simple/simple_encoder.c",
                "src/liblzma/simple/sparc.c",
                "src/liblzma/simple/x86.c"
            ],
            publicHeadersPath: "src/liblzma/api",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("src/liblzma/api"),
                .headerSearchPath("src/liblzma/common"),
                .headerSearchPath("src/liblzma/check"),
                .headerSearchPath("src/liblzma/lz"),
                .headerSearchPath("src/liblzma/rangecoder"),
                .headerSearchPath("src/liblzma/lzma"),
                .headerSearchPath("src/liblzma/delta"),
                .headerSearchPath("src/liblzma/simple"),
                .headerSearchPath("src/common"),
                .headerSearchPath("floe"),
            ]
        ),
        .target(
            name: "CArchive",
            path: "Vendor/Archive/libarchive-3.8.9",
            sources: [
                "libarchive/archive_acl.c",
                "libarchive/archive_blake2s_ref.c",
                "libarchive/archive_blake2sp_ref.c",
                "libarchive/archive_check_magic.c",
                "libarchive/archive_cmdline.c",
                "libarchive/archive_cryptor.c",
                "libarchive/archive_digest.c",
                "libarchive/archive_entry.c",
                "libarchive/archive_entry_copy_stat.c",
                "libarchive/archive_entry_link_resolver.c",
                "libarchive/archive_entry_sparse.c",
                "libarchive/archive_entry_stat.c",
                "libarchive/archive_entry_strmode.c",
                "libarchive/archive_entry_xattr.c",
                "libarchive/archive_hmac.c",
                "libarchive/archive_match.c",
                "libarchive/archive_options.c",
                "libarchive/archive_pack_dev.c",
                "libarchive/archive_parse_date.c",
                "libarchive/archive_pathmatch.c",
                "libarchive/archive_ppmd7.c",
                "libarchive/archive_ppmd8.c",
                "libarchive/archive_random.c",
                "libarchive/archive_rb.c",
                "libarchive/archive_read.c",
                "libarchive/archive_read_add_passphrase.c",
                "libarchive/archive_read_append_filter.c",
                "libarchive/archive_read_data_into_fd.c",
                "libarchive/archive_read_disk_entry_from_file.c",
                "libarchive/archive_read_disk_posix.c",
                "libarchive/archive_read_disk_set_standard_lookup.c",
                "libarchive/archive_read_extract.c",
                "libarchive/archive_read_extract2.c",
                "libarchive/archive_read_open_fd.c",
                "libarchive/archive_read_open_file.c",
                "libarchive/archive_read_open_filename.c",
                "libarchive/archive_read_open_memory.c",
                "libarchive/archive_read_set_format.c",
                "libarchive/archive_read_set_options.c",
                "libarchive/archive_read_support_filter_all.c",
                "libarchive/archive_read_support_filter_by_code.c",
                "libarchive/archive_read_support_filter_bzip2.c",
                "libarchive/archive_read_support_filter_compress.c",
                "libarchive/archive_read_support_filter_grzip.c",
                "libarchive/archive_read_support_filter_gzip.c",
                "libarchive/archive_read_support_filter_lrzip.c",
                "libarchive/archive_read_support_filter_lz4.c",
                "libarchive/archive_read_support_filter_lzop.c",
                "libarchive/archive_read_support_filter_none.c",
                "libarchive/archive_read_support_filter_program.c",
                "libarchive/archive_read_support_filter_rpm.c",
                "libarchive/archive_read_support_filter_uu.c",
                "libarchive/archive_read_support_filter_xz.c",
                "libarchive/archive_read_support_filter_zstd.c",
                "libarchive/archive_read_support_format_7zip.c",
                "libarchive/archive_read_support_format_all.c",
                "libarchive/archive_read_support_format_ar.c",
                "libarchive/archive_read_support_format_by_code.c",
                "libarchive/archive_read_support_format_cab.c",
                "libarchive/archive_read_support_format_cpio.c",
                "libarchive/archive_read_support_format_empty.c",
                "libarchive/archive_read_support_format_iso9660.c",
                "libarchive/archive_read_support_format_lha.c",
                "libarchive/archive_read_support_format_mtree.c",
                "libarchive/archive_read_support_format_rar.c",
                "libarchive/archive_read_support_format_rar5.c",
                "libarchive/archive_read_support_format_raw.c",
                "libarchive/archive_read_support_format_tar.c",
                "libarchive/archive_read_support_format_warc.c",
                "libarchive/archive_read_support_format_xar.c",
                "libarchive/archive_read_support_format_zip.c",
                "libarchive/archive_string.c",
                "libarchive/archive_string_sprintf.c",
                "libarchive/archive_time.c",
                "libarchive/archive_util.c",
                "libarchive/archive_version_details.c",
                "libarchive/archive_virtual.c",
                "libarchive/archive_write.c",
                "libarchive/archive_write_add_filter.c",
                "libarchive/archive_write_add_filter_b64encode.c",
                "libarchive/archive_write_add_filter_by_name.c",
                "libarchive/archive_write_add_filter_bzip2.c",
                "libarchive/archive_write_add_filter_compress.c",
                "libarchive/archive_write_add_filter_grzip.c",
                "libarchive/archive_write_add_filter_gzip.c",
                "libarchive/archive_write_add_filter_lrzip.c",
                "libarchive/archive_write_add_filter_lz4.c",
                "libarchive/archive_write_add_filter_lzop.c",
                "libarchive/archive_write_add_filter_none.c",
                "libarchive/archive_write_add_filter_program.c",
                "libarchive/archive_write_add_filter_uuencode.c",
                "libarchive/archive_write_add_filter_xz.c",
                "libarchive/archive_write_add_filter_zstd.c",
                "libarchive/archive_write_disk_posix.c",
                "libarchive/archive_write_disk_set_standard_lookup.c",
                "libarchive/archive_write_open_fd.c",
                "libarchive/archive_write_open_file.c",
                "libarchive/archive_write_open_filename.c",
                "libarchive/archive_write_open_memory.c",
                "libarchive/archive_write_set_format.c",
                "libarchive/archive_write_set_format_7zip.c",
                "libarchive/archive_write_set_format_ar.c",
                "libarchive/archive_write_set_format_by_name.c",
                "libarchive/archive_write_set_format_cpio.c",
                "libarchive/archive_write_set_format_cpio_binary.c",
                "libarchive/archive_write_set_format_cpio_newc.c",
                "libarchive/archive_write_set_format_cpio_odc.c",
                "libarchive/archive_write_set_format_filter_by_ext.c",
                "libarchive/archive_write_set_format_gnutar.c",
                "libarchive/archive_write_set_format_iso9660.c",
                "libarchive/archive_write_set_format_mtree.c",
                "libarchive/archive_write_set_format_pax.c",
                "libarchive/archive_write_set_format_raw.c",
                "libarchive/archive_write_set_format_shar.c",
                "libarchive/archive_write_set_format_ustar.c",
                "libarchive/archive_write_set_format_v7tar.c",
                "libarchive/archive_write_set_format_warc.c",
                "libarchive/archive_write_set_format_xar.c",
                "libarchive/archive_write_set_format_zip.c",
                "libarchive/archive_write_set_options.c",
                "libarchive/archive_write_set_passphrase.c",
                "libarchive/filter_fork_posix.c",
                "libarchive/xxhash.c"
            ],
            publicHeadersPath: "libarchive",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .define("LIBARCHIVE_STATIC"),
                .define("__LIBARCHIVE_ENABLE_VISIBILITY"),
                .define("NDEBUG"),
                .headerSearchPath("libarchive"),
                .headerSearchPath("floe"),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(name: "CFloeArchive", dependencies: ["CBZip2", "CLzma"],
                path: "Sources/CFloeArchive",
                publicHeadersPath: "include"),
        .target(name: "SMBClient",
                dependencies: [.product(name: "Crypto", package: "swift-crypto")],
                path: "Vendor/Network/SMBClient-0.2.1/Sources/SMBClient",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "FloeWorkspace", dependencies: [
            "FloeCore", "FloeModels", "FloeTools",
            "CFloeArchive", "CZLib", "ZIPFoundation", "SWCompression", "SMBClient", "CArchive",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .target(name: "FloeBrowser", dependencies: [
            "FloeCore", "FloeModels", "FloeTools", "FloeTransport",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .target(name: "FloeAndroidJobTools", dependencies: [
            "FloeCore", "FloeModels", "FloeTools", "FloePersistence", "FloeAndroidShellTools",
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
            "FloeAndroidWebTools", "FloeAndroidShellTools", "FloeAndroidJobTools", "FloeAndroidWorkspaceTools",
            "FloeWorkspace", "FloeGit", "FloeBrowser",
            // G03-R1 environment authority: links the original registry/
            // coordinator/lease authority into the product .so (dependency
            // only; NO ToolEnvironmentRouting registration, NO backend
            // selection — trusted composition supplies root+backend and the
            // linuxruntime lane consumes the lease descriptor).
            "FloeEnvironments",
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
        .testTarget(name: "FloeAndroidShellToolsTests", dependencies: [
            "FloeAndroidShellTools", "FloeAndroidCore", "FloeCore", "FloeTools",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .testTarget(name: "FloeAndroidJobToolsTests", dependencies: [
            "FloeAndroidJobTools", "FloeAndroidShellTools", "FloeCore", "FloeModels", "FloeTools", "FloePersistence",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .testTarget(name: "FloeGitTests", dependencies: [
            "FloeGit", "FloeCore", "FloeModels", "FloeTools", "FloeTransport",
            "libgit2",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .testTarget(name: "FloeBrowserTests", dependencies: [
            "FloeBrowser", "FloeCore", "FloeModels", "FloeTools", "FloeTransport",
        ], swiftSettings: strictSettings),
        .testTarget(name: "FloeWorkspaceTests", dependencies: [
            "FloeWorkspace", "FloeCore", "FloeTools", "CFloeArchive", "ZIPFoundation",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        // G03-R2 workspace transfer suites (job-4d35db884ec64d95 cohort, per
        // Main's dependency note): the engine/path suites run on the REAL
        // host filesystem in temporary directories; the grant-proof suites
        // exercise the module's own HMAC/Crypto surface. FloeAndroidCore is
        // NOT required (the 15 authored engine/path tests never import it);
        // the trusted-selector path is qualified on device in R3.
        .testTarget(name: "FloeAndroidWorkspaceToolsTests", dependencies: [
            "FloeAndroidWorkspaceTools", "FloeCore", "FloeTools",
            .product(name: "Crypto", package: "swift-crypto"),
        ], swiftSettings: strictSettings),
        .testTarget(name: "FloeAndroidCoreTests", dependencies: [
            "FloeBrowser", "FloeAndroidCore", "FloeCore", "FloeModels", "FloePersistence", "GRDB",
            "FloeWorkspace",
            // G02-P3 transport suites: the REAL incremental seam + provider
            // pump/MCP collect bodies run on the host against synthetic
            // loopback fixtures (compiled identically to the Android build).
            "FloeTransport", "FloeProviders", "FloeTools",
            // D1 web closure suites: the Android streaming/collect bodies +
            // session constructions above run against the same loopback
            // fixtures; original tool/service semantics are tested directly.
            "FloeAndroidWebTools",
            // G03-R1 ownership/rejection suites for the ported environment
            // authority and the lease descriptor (authored, host-runnable).
            "FloeEnvironments",
        ], swiftSettings: strictSettings)
    ]
)
