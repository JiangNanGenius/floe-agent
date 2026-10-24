# SMBClient 0.2.1 — vendored with 3 documented Android patch sites

Upstream: https://github.com/kishikawakatsumi/SMBClient.git version 0.2.1
(tag tarball SHA-256 4283227d187be6daba0edc2b24bee4df074315bd3c2217a4c31bd35d22623df7,
verified 2026-10-24). MIT license retained. The package graph pins exactly
this version (public FloeAgent/Package.swift rule) — not any similarly named
package. Dialects requested by untouched upstream code are
`[.smb202, .smb210]`: no SMB1, no anonymous fallback path exists in this
library, so the original auth requirements are preserved by construction.

Of 78 `Sources/SMBClient/**` files, 75 are byte-identical to upstream (hash
manifest in r1/archive-network/SOURCE_READY.json lists per-file identity vs
the tarball). Exactly 3 files carry narrow patches; each preserves the
upstream body on Apple platforms and adds an `#else` branch for Android
(a single `FLOE_PORTABLE_SMB` define can force the portable branch on Apple
hosts for verification builds):

1. `Sources/SMBClient/Connection.swift`
   - upstream NWConnection transport kept byte-identical under
     `canImport(Network) && !FLOE_PORTABLE_SMB`;
   - `#else`: blocking POSIX TCP socket (getaddrinfo/socket/connect/
     setsockopt TCP_NODELAY (+ SO_NOSIGPIPE on Darwin), send/recv with
     MSG_NOSIGNAL on Glibc) on a serial DispatchQueue; same Semaphore
     request serialization; frame-boundary-exact reads (documented delta #1:
     completes the 4-byte DirectTCP length prefix before parsing); the
     framing logic (DirectTCPPacket accumulation, prefix/suffix buffer
     accounting, `nextCommand` chained-command walk, SMB2 PENDING re-read)
     is upstream's algorithm reused verbatim; same public surface
     (`init(host:)`, `init(host:port:)`, `connect`, `disconnect`, `send`,
     `onDisconnected`) and same `ConnectionError` cases so the module's
     `classifySMB` mapping is unchanged. No `NWConnection.State` exposure on
     the portable branch (no other file reads it). No credentials ever pass
     through this class.
2. `Sources/SMBClient/Auth/Crypto.swift`
   - CommonCrypto-backed `randomBytes`/`hmacMD5`/`hmacSHA256`/`rc4` gain a
     portable branch: bionic `arc4random_buf` CSPRNG, swift-crypto
     (`HMAC<Insecure.MD5>`, `HMAC<SHA256>` — the exact revision already
     pinned in this package graph), and standard RC4 KSA/PRGA (byte-identical
     keystream; used by upstream only for the NTLM session-key wrap);
   - the pure-Swift MD4 is upstream code, unmodified.
3. `Sources/SMBClient/Auth/NTLM.swift`
   - its unused `import CommonCrypto` becomes conditional (verified: no CC
     symbol is referenced in the file; all primitives come from the Crypto
     seam above). Rest byte-identical.

SwiftPM target proposed for Main:
```swift
.target(name: "SMBClient",
        dependencies: [.product(name: "Crypto", package: "swift-crypto")],
        path: "Vendor/Network/SMBClient-0.2.1/Sources/SMBClient",
        swiftSettings: [.swiftLanguageMode(.v5)])
```
`FloeWorkspace` gains the `SMBClient` dependency. Only LAN-reachable servers
are affected by Android `ACCESS_LOCAL_NETWORK` at targetSdk 37 — that stays
App-owned availability gating (never granted from module code); WebDAV over
public HTTPS needs no new permission. See TLS_TRUST_ADAPTER_HANDOFF.md in the
lane output scope for the session/trust adapter requirement Main must satisfy
at wiring (shared with the git transport lane; one trust authority).

## Android object-build correction (2026-10-24)

The first actual Android Core object build found that the portable transport selected only Glibc/Darwin imports. The Swift Android SDK exposes these Bionic POSIX APIs through the Android module. Connection.swift now imports Android first when available and qualifies connect/send/recv with that module; MSG_NOSIGNAL remains in use for Android sends. The original Apple Network.framework branch, DirectTCP framing, credentials and protocol behavior are unchanged. The upstream archive pin is unchanged. Native object compilation is required to qualify this correction.
