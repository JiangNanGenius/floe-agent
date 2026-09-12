# Floe shell binary provenance

The seven command/engine targets use the exact URLs and SHA-256 values in
`holzschu/ios_system` tag v3.0.4, which references v3.0.2 binary releases.

`otool -L` on the downloaded iOS binaries established that curl_ios additionally
requires `libssh2.framework` and `openssl.framework`. Their URLs come from the
upstream `xcfs/Package.swift` dependency build manifest.

The OpenSSL v1.1.1w release asset was republished upstream on 2025-09-28. Its old
xcfs-manifest checksum fails verification. The pinned replacement SHA-256
`329e8317cf9bee8e138da5d032330a7a1bd2473cf44c9c083cb2f0636abb8b80`
was checked against the GitHub release asset's `digest` and the independently
downloaded archive on 2026-09-12. Artifact: `openssl-dynamic.xcframework.zip`,
13,879,626 bytes. No checksum enforcement was disabled.

This is a development baseline. It does not establish workspace filesystem
confinement, thread/cwd/environment isolation, or production qualification of
these older native libraries. See docs/ARCHITECTURE_LOCAL_SHELL.md.
