# Floe iOS Bridge

A standalone, self-signed iPhone and iPad app for local device automation. One universal IPA contains the native setup interface, its own local development tunnel, a shared service core and an embedded automation engine. Requires iOS/iPadOS 26 or later. Main Floe app integration is outside this release.

Source checks, App compilation, signing/install, physical-device behavior and public downloads are recorded separately. Check the [release centre](https://www.floe-agent.com/releases?platform=ios-bridge) for available packages and each release's qualification scope. Historical [prototype evidence](Qualification/RECOVERY_GATE.md) does not qualify a different package.

[中文说明](README.zh-CN.md) · [Install and use](INSTALL.md) · [安装与使用](INSTALL.zh-CN.md)

## Use

Complete signing, installation and developer pairing once with a computer. Then open Bridge on the device and start the service; after a reboot, unlock the device and open Bridge again. No separate runtime helper app is required. Signature expiry or invalid developer pairing may require a computer again. Bridge neither signs in to an Apple ID nor issues certificates.

The primary connection is on the same device:

- `http://127.0.0.1:8200`
- `http://[::1]:8200`

Every fresh client needs approval inside Bridge. LAN access and same-LAN Bonjour are separate owner options, both off by default. No peer-to-peer discovery or normal internet default route is installed. The internal tunnel routes only the local development-service address. Developer images are downloaded or imported on demand and never bundled in the IPA.

1.0 covers tap, swipe, text input, app switching, screen reading/OCR, screenshots, live video and a browser remote page. Current `/schema` capabilities are authoritative; unsupported system/private functions return explicit errors. Third-party app password input needs a separate per-client owner grant, off by default. Device passcode and system authentication remain manual on the device.

## Protocol and clients

`/pair`, `/rpc`, `/schema`, `/skill`, `/stream` and `/remote` share the same service/authentication state. Pairing keys and nonce history persist in the Keychain; revocation closes client access and streams. Requests use the pinned iCTRL v1 encrypted-envelope contract. Gesture coordinates are screen points.

Read the bundled [protocol manual](Resources/BridgeRPC/SKILL.md) and [reference client guide](scripts/RemoteClient/README.md). The native interface and the automation engine use the same `BridgeCore` registries. XCTest initializes once per process, after a developer image is available. Stop closes admission and fences later work; a subsequent start reuses the initialized engine. A failed initializer requires reopening the app.

## Build and sign

Requirements: Xcode 27.1, XcodeGen and Python 3. Start from a frozen commit containing the complete `FloeIOSBridge/` tree. Regenerate and commit the matching Xcode project before freezing source:

```sh
bash FloeIOSBridge/scripts/gen_project.sh
```

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
bash FloeIOSBridge/scripts/build_bridge.sh --mode release --source-ref <40-hex-commit>
```

Release mode uses the committed project, validates pinned dependencies and source binding, builds arm64 device objects and exports an unsigned IPA, symbols and private evidence. It does not sign, install or publish. Use a task-specific internal SSD cache through `FLOE_BRIDGE_CACHE`; compilation is serialized with six jobs by default.

The public assets are `Floe-iOS-Bridge-<version>-unsigned.ipa`, its `.sha256`, and a minimal `-public.json` summary. Private device qualification signs this same product-content IPA with `scripts/sign_bridge_ipa.sh --mode product-qualification`; use `--help` for profile/identity parameters. The signing helper verifies nested signatures, entitlements and profiles. A developer signing setup with Network Extension is required; free Apple IDs and arbitrary re-signing tools are not promised.

`qualification` is a historical prototype build mode; it is not a release fallback. `product-qualification` preserves product content while allowing private signatures. Signed IPAs, profiles, device identifiers, pairing records, logs and symbols must never be public assets.

The independent tag family is `floe-ios-bridge-v<version>`. The publisher defaults to read-only verification; explicit `--publish` requires an immutable pushed tag, matching public assets and a private receipt from actual qualification. It publishes stable with `make_latest=false`, leaving the main Floe and macOS Bridge release/feed paths unchanged.

When the owner explicitly accepts reboot recovery without another device run, the private receipt records `checks.rebootRecovery` as `assumed-by-owner`. The publisher requires that limitation in public release notes; it does not accept this value for other iPhone checks.

## Verification and licensing

Focused checks live under `Tests/` and `scripts/run_core_checks.sh`; the primary owner runs the final App build and device acceptance. Physical iPad testing is waived by the project owner: compatibility is assumed for the universal target and must not be described as hardware-tested. Simulator/component results do not prove DDI recovery, background control or reboot recovery.

Automation and protocol adaptations derive from Apache-2.0 [OpenMinis/iCTRL](https://github.com/OpenMinis/iCTRL/tree/c1e4268859ba858d1579f7b846a56cb40641b7f6); the local development connection uses MIT `idevice` pinned in `Vendor/idevice.lock.json`. Preserve [third-party notices](ThirdParty/iCTRL/NOTICE.md), upstream licenses, dependency notices and adaptation records. See [historical prototype guide](Qualification/PROTOTYPE_GUIDE.md) only when reproducing old private builds.
