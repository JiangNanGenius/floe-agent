# Floe Android Citadel vendor slice

Upstream: https://github.com/orlandos-nl/Citadel.git
Commit:   `ae8562f895de06ccb86fdb1cbb65fd99c8976e12` (MIT, `LICENSE`)
Purpose:  the C05 SSH/SFTP transport on Android. This is a source slice, not
          a fork: every file under `Sources/Citadel` and
          `Sources/CCitadelBcrypt` is byte-identical to that upstream commit
          **except** the added file listed below. Upstream demos, the
          `CitadelServerExample` executable, unit tests, Dockerfile and
          examples are not shipped.

## Local changes (complete list)

1. Added `Sources/Citadel/SFTP/Client/SFTPSubsystemChannel.swift`.
   * `SSHClient.openSFTPSubsystemChannel(logger:timeout:)` sends a real
     `SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp",
     wantReply: true)` on a new session channel of the existing authenticated
     connection and returns the raw `Channel` after the server accepts it.
   * It adds only the SSH byte wrappers (`SSHChannelDataUnwrapper`,
     `SSHOutboundChannelDataWrapper`) and a private reply observer; it installs
     no SFTP parser, no request decoder and no directory accumulator.
   * On refusal it throws `SSHSubsystemError.subsystemRejected`; on a channel
     open or reply timeout it closes the opened child channel and throws
     `.timeout`.
   * This exists because the pinned revision's `SFTPClient.listDirectory`
     materializes the complete directory and its channel/decoder are not
     public. C05 needs a byte-level SFTP v3 listing codec with explicit
     per-frame, per-page and byte caps. The new API reuses Citadel's proven
     channel/subsystem machinery instead of duplicating NIOSSH plumbing.
   * Nothing else in Citadel is modified; `SFTPClient` stat/read/write/
     rename/mkdir/rmdir paths are untouched.

2. Replaced `Package.swift`.
   * Removed the `ColorizeSwift` dependency (only the omitted example used
     it), the `CitadelServerExample` executable target and the `CitadelTests`
     test target so the slice resolves without the omitted directories.
   * The library product, the two targets, the dependency ranges and the
     platform declaration are unchanged from upstream.

## Not part of the patch

`Package.resolved` is not shipped in this slice. The FloeAndroid package keeps
its own `shared/Package.resolved` exact pins (swift-nio 2.88.0,
swift-nio-ssh 0.3.6, swift-log 1.15.0, BigInt 5.7.0, swift-atomics 1.3.1,
swift-collections 1.6.0, swift-system 1.8.0, swift-crypto
`95ba0316a9b733e92bb6b071255ff46263bbe7dc`). Those pins continue to govern
the graph; only the Citadel entry moves from a remote revision to this local
path dependency.
