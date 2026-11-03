# Upstream adaptations — Bridge RPC 1.0

Pinned source: OpenMinis/iCTRL, commit
`c1e4268859ba858d1579f7b846a56cb40641b7f6` (tag v1.98.16), Apache-2.0.
No local upstream checkout is required or assumed; files were obtained through
the GitHub API at that exact revision.

## Adapted

- **Wire contract** — `iCTRLKit/SecureEnvelope.swift` and the pairing section of
  `iCTRLKit/AuthManager.swift`: direction labels `ictrl-v1|enc-req`,
  `ictrl-v1|enc-resp`, `ictrl-v1|mac`, the PRF-CTR (not AES-GCM) keystream,
  32-byte key, 8-hex token id, 16-byte nonce, ±120 s timestamp window, 30-day
  idle expiry, X25519 `ictrl-pair`/`ictrl-wrap` key wrap, and the single-use
  stream ticket model. `Sources/BridgeCore/RPC/BridgeRPCEnvelope.swift` is an
  independent implementation of these primitives; `BridgeRPCAuthority.swift`
  independently implements approval, idle expiry, replay rejection,
  revocation, revision fencing and durable nonce persistence.
- **Method surface** — `iCTRLKit/RPCMethod.swift` and `RPCTypes.swift`: all 33
  method names and their parameter names/types are preserved for existing
  automation clients. Descriptions are shortened/rewritten for Floe Bridge;
  implementation is not imported. Unimplemented methods are reported as
  unavailable, never stub-success.
- **HTTP surface** — endpoint names and status semantics from
  `iCTRLKit/JSONRPCServer.swift`: `/pair`, `/rpc`, `/schema`, `/skill`,
  `/skill.md`, `/stream`, `/logs*`, `/remote`, and the `stream_ticket` special
  authenticated method. The Floe transport is an independent bounded BSD-socket
  server with mandatory dual-stack loopback, optional normal-LAN only, and a
  final first-byte commit gate; it does not copy the upstream NWListener,
  NearbyAdvertiser, video pipeline, remote page or credential files.
- **Manual semantics** — the skill-style setup/error guidance follows the
  upstream `SKILL.md`; the shipped `SKILL.md` is rewritten for this package and
  does not claim upstream methods are implemented here.

## Not imported

`NearbyAdvertiser`/AWDL, peer-to-peer Wi-Fi, the XCTest action runner, private
C/accessibility shims, OCR/browser/reference implementations, the H.264 stream
encoder, the remote control page, the upstream token file store, and any
auto-approval environment variable. There is no prototype PSK migration here.
