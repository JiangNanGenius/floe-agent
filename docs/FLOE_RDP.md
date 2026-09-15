# Native RDP integration — development status

RDP is being added alongside VNC. It reuses the visual-evidence and input-tool
contract, while protocol negotiation, credentials and session ownership remain
separate. It is not yet advertised as an available capability or delivered in a
new TestFlight build.

## Native foundation

FreeRDP 3.31.1 and OpenSSL 4.0.1 are pinned in
`FloeAgent/ThirdParty/FreeRDP/runtime.lock.json`. Dependency run
[34976735993](https://github.com/JiangNanGenius/floe-agent/actions/runs/34976735993)
passed for arm64 iOS and arm64 iOS Simulator. Fourteen restored library hashes
matched their archived manifests. Both upstream licenses accompany artifacts.

`Bridge/FloeRDP.c` uses one worker for connection, decoding and input dispatch.
The input queue holds at most 16,384 events and admits whole batches atomically;
it drains 256 events per iteration. Frame dimensions are limited to 4096 per
axis and 32 MiB. Stop aborts connection/event waits; destruction joins the worker
before freeing callbacks or protocol memory. Certificate validation must be
provided by the caller; there is no automatic accept or ignore-certificate path.
TLS/NLA are enabled, legacy RDP security and device/clipboard redirection are off.

The bridge compiles with warnings treated as errors and links with the restored
native dependencies on both Apple targets. This validates symbols and platform
framework dependencies, not a working remote session. The cloud bridge workflow
reuses the immutable native build instead of recompiling OpenSSL for bridge edits.

## Remaining acceptance

- System certificate trust and explicit per-endpoint certificate confirmation.
- Swift session ownership, Keychain-backed host settings, viewer and input UI.
- Agent tool registration only when the runtime and endpoint are usable.
- Real authentication, framebuffer changes, input, cancellation, repeated
  connect/disconnect, rejected certificates and resource-lifetime tests.
- Complete App integration, iPad/iPhone flows and final distribution evidence.

## 2026-09-16 connection evidence

[Loopback run 34985585747](https://github.com/JiangNanGenius/floe-agent/actions/runs/34985585747),
source `760566f8d2ed468daf8e599f3391066cf37299c1`, passed real TLS RDP traffic
against an ephemeral xrdp desktop: rejected certificate, three connection/frame/
click/scan-code/close cycles, oversized input batch rejection and cancellation
while connecting. The test checks a known desktop color and the actual key events
received by the remote application. It retains desktop pixels and session evidence.
[Machine-readable result](evidence/floe-1.7/rdp/loopback-760566f8.json).
This is a Linux bridge qualification with system OpenSSL and an xrdp VNC backend;
it does not establish Windows NLA interoperability or iPad App acceptance.

The Swift facade and certificate/tool routing code passed targeted Swift 6.4 type
checking against the native C module. The facade owns its worker independently of
views and joins before freeing callbacks. Input failure closes only that session;
RDP tool guidance keeps the `rdp.*` namespace without rewriting document content.
Four targeted native tests passed with Swift 6.4 and the macOS 27 SDK: unknown
self-signed certificates require confirmation, exact pins accept while mismatches
reject, malformed chains/pins reject, and RDP tool guidance preserves its namespace.
This tests Apple Security and current Swift routing code, not an Apple RDP session.
The complete App cloud suite remains required.

The App does not yet link or advertise this runtime. Host settings, per-endpoint
Keychain credentials and trust confirmation, viewer, tool registration and App
qualification remain required before claiming RDP availability.
