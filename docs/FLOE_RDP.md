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

No RDP server, authentication or remote input acceptance is claimed yet.
