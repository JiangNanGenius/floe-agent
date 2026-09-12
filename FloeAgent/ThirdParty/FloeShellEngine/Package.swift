// swift-tools-version:5.3
// Binary URLs/checksums from ios_system v3.0.4; only the approved command set.
import PackageDescription

let package = Package(
    name: "FloeShellEngine",
    products: [.library(name: "FloeShellEngine", targets: ["ios_system", "awk", "curl_ios", "files", "shell", "tar", "text", "libssh2", "openssl"])],
    targets: [
        // Dynamic dependencies required by the pinned curl_ios binary.
        .binaryTarget(name: "libssh2", url: "https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0/libssh2-dynamic.xcframework.zip", checksum: "cacfe1789b197b727119f7e32f561eaf9acc27bf38cd19975b74fce107f868a6"),
        .binaryTarget(name: "openssl", url: "https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip", checksum: "329e8317cf9bee8e138da5d032330a7a1bd2473cf44c9c083cb2f0636abb8b80"),
        .binaryTarget(
            name: "ios_system",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.2/ios_system.xcframework.zip",
            checksum: "f8e1364037de546809065ecdf804277fa7b95faffc32604e91ecb4de44d6294e"
        ),
        .binaryTarget(
            name: "awk",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.2/awk.xcframework.zip",
            checksum: "73abc0d502eab50e6bbdd0e49b0cf592f3a85b3843c43de6d7f42c27cde9b953"
        ),
        .binaryTarget(
            name: "curl_ios",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.2/curl_ios.xcframework.zip",
            checksum: "7338fb9ae8094356c8cd523cfda9e4c60b52d710488432eb64cf57731b388dd2"
        ),
        .binaryTarget(
            name: "files",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.2/files.xcframework.zip",
            checksum: "d0643e2244009fc5279f1f969c6da47ca197b4e7c9dac27dea09ba0a5f1567d7"
        ),
        .binaryTarget(
            name: "shell",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.2/shell.xcframework.zip",
            checksum: "876b709c1b76cbc1748d434fcbc2cea1aea2e281572e5fadc40244dd8a549757"
        ),
        .binaryTarget(
            name: "tar",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.2/tar.xcframework.zip",
            checksum: "6ffe4ed265060f971df229dd1d2bff90e7bc78c80c50dcc3a0a633face440bc4"
        ),
        .binaryTarget(
            name: "text",
            url: "https://github.com/holzschu/ios_system/releases/download/v3.0.2/text.xcframework.zip",
            checksum: "697bee697b509d0dc8acc156a7430f453c29878d8af273adfb8902643c70ea0f"
        )
    ]
)
