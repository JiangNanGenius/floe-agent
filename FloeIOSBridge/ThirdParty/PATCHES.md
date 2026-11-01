# Third-party provenance and local changes

## OpenMinis/iCTRL

- Upstream: <https://github.com/OpenMinis/iCTRL>
- Revision: `c1e4268859ba858d1579f7b846a56cb40641b7f6` (tag v1.98.16)
- License: Apache-2.0 (`LICENSE`), `NOTICE.md` retained.
- Fetched with a depth-1 fetch of the exact revision; no `main` HEAD drift.

Adapted into this prototype (all rewritten in Swift for the independent host):

- `iCTRLApp/DDI/DDIMounter.swift` → `Sources/BridgeHost/BridgeDDIManager.swift`:
  preserved the idevice FFI sequencing (RPPairing tunnel, existing
  image/cryptex checks, cryptexd or personalized mount, ECID, 4 MiB worker
  thread, progress callback, error mapping). Replaced the external
  LocalDevVPN dependency with this app's own Packet Tunnel provider, added
  Keychain-backed staging and generation/lifecycle reporting.
- `iCTRLApp/DDI/DeveloperDiskImageStore.swift` →
  `Sources/BridgeHost/BridgeDDIStore.swift`: runtime-only download/import,
  bounded staged downloads, size/plist validation, atomic import set swap,
  provenance hashes. The mirror URL is kept as a runtime source, never bundled.
- `iCTRLApp/DDI/PairingFileStore.swift` →
  `Sources/BridgeHost/BridgePairingStore.swift`: RPPairing validation with the
  pinned FFI parser, but the record is stored in the Keychain
  (`AfterFirstUnlockThisDeviceOnly`) and staged only for the FFI worker with
  complete file protection. Raw parser text is not surfaced or logged.
- `iCTRLKit/DeveloperDiskImage.swift` → `Sources/BridgeCore/BridgeTransport.swift`
  and `BridgeDDIProbe.swift`: layout probe only; no runner/DDI execution logic.
- `iCTRLKit/SecureEnvelope.swift` → `Sources/BridgeCore/BridgeLANCrypto.swift`:
  independently adapted the v1 envelope construction (HMAC-SHA256
  direction-separated keys, PRF-CTR keystream, `v1`/`tok`/`ts`/`nonce`/`ct`/`tag`
  binding, ±120 s timestamp window). The control key is a separate provisioned
  32-byte credential, not the iCTRL pairing key and not the read-only bearer.
  The prototype implements the cipher/wire contract only; it does not provide
  upstream `/pair`, `/rpc`, `/skill`, `/schema`, `/stream` or `/logs` parity.
  `Sources/BridgeCore/BridgeLANProtocol.swift` and `BridgeLANServer.swift` are
  original bounded HTTP/auth/replay/fencing code, not copied upstream.
- `iCTRLUITests/ActionHandler.swift` and `FastActionHandler.swift` →
  `Sources/BridgeTests/BridgeEngineTests.swift` +
  `Sources/BridgeCore/BridgeControlArguments.swift` (Build 12 source, repaired
  read/input/Home source): adapted the public-XCTest semantics for foreground
  binding, one-snapshot bounded reads, unique identifier resolution, normalized
  gesture arguments and focus-aware text input. The prototype adds a closed
  typed-argument schema, LAN/file binding digests, secure-field refusal,
  dispatch-versus-verified result wording, a depth-40 bounded tree default
  (upstream `pageSource` default) with a lazy budgeted snapshot adapter,
  explicit identifier/label/placeholder/point text targeting through the SDK
  `typeText` focus assertion, scoped XCTest `record(_:)` issue capture and
  append-only value evidence, and separate source-departure/SpringBoard Home
  evidence.
  It does not import the private `ForegroundApp` C shim or the upstream RPC
  server. Details: `ThirdParty/iCTRL/ADAPTATIONS.md`.

Not copied: LocalDevVPN/StosVPN custom-license tunnel source, StikDebug AGPL
source, ldid or any legacy signer. The internal reflector is an independent
implementation of the address-swap behavior documented by the pinned upstream.

## jkcoxson/idevice

- Upstream: <https://github.com/jkcoxson/idevice>
- Release: v0.1.68, annotated tag object `75c7a083bba231315af56b202f69c5db45c1b928`,
  commit `d32c8189c51c2789496b0768039419c3705498c3`
- License: MIT (`ThirdParty/idevice/LICENSE`)
- Asset: `idevice-xcframework-v0.1.68.zip`
  SHA-256 `c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7`
- Only the iOS arm64 static slice is used; it is fetched by
  `scripts/fetch_idevice.sh` and not committed. The slice archive hash is pinned
  in `Vendor/idevice.lock.json`.
- No source changes are made to the dependency.

## Developer Disk Image source

Apple does not publish the personalized DDI for direct download. The app uses
the runtime mirror maintained by doronz88/DeveloperDiskImage
(`PersonalizedImages/Xcode_iOS_DDI_Cryptex` or
`Xcode_iOS_DDI_Personalized`) or a user-imported folder. The DDI is never part
of the IPA; downloaded files are recorded with size and SHA-256 in
`diagnostics/ddi-source.json` after validation.
