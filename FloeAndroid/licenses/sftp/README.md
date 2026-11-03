# C05 SFTP transport source and licence lineage

The Android C05 SFTP file channel uses the existing C05 SSH dependency. No
new third-party library, SDK, binary or service is added by the bounded
directory-listing repair.

| Component | Origin | Revision | Licence |
| --- | --- | --- | --- |
| Citadel source slice | https://github.com/orlandos-nl/Citadel.git | `ae8562f895de06ccb86fdb1cbb65fd99c8976e12` | MIT (`licenses/ssh/Citadel-LICENSE.txt`) |
| SwiftNIO / SwiftNIO SSH / BigInt / swift-log / swift-crypto | existing C05 SSH pins | unchanged | see `licenses/ssh/README.md` |

## Why a source slice exists

The pinned Citadel revision's public `SFTPClient.listDirectory` collects the
entire remote directory into one array and its child channel/decoder are not
public. C05 requires a bounded SFTP v3 directory page with explicit
entry/byte/frame caps, request matching, a real directory-handle CLOSE and a
real SSH `sftp` subsystem request.

`shared/Vendor/SSH/Citadel` is therefore the pinned Citadel source slice with
exactly one added file,
`Sources/Citadel/SFTP/Client/SFTPSubsystemChannel.swift`. It exposes
`SSHClient.openSFTPSubsystemChannel(logger:timeout:)`, which sends the actual
`SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)`
on a new channel of the authenticated connection and returns the raw byte
channel. No shell, `exec` request, remote helper path or install step is used.
Every other Citadel source file is byte-identical to the pinned commit; the
slice's `Package.swift` only removes the upstream example and test targets.
The full change list and per-file hashes are in the slice's
`FLOE_PATCHES.md` and in the private C05 SFTP subsystem handoff manifest.

No shared SwiftPM cache, lockfile bypass or floating revision is used. The
Citadel package moves from the remote revision to the local slice; every
other dependency pin in `shared/Package.resolved` stays unchanged. Main owns
`shared/Package.swift` and `shared/Package.resolved`.

The bounded listing implementation itself is in
`shared/Sources/FloeSSH/SSHSFTPService.swift`. Existing PTY, exec,
direct-tcpip, host-key and credential services are unchanged.
