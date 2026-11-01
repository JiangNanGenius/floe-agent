# BootstrapCanary

A narrow, one-app physical-device canary for the normal-host XCTest bootstrap path.
It is not the iCTRL engine, tunnel, DDI mounter or a complete single-IPA product.

## What it builds

- One ordinary UIKit host app with bundle ID `org.floeagent.iosbridge`.
- One embedded UI-test bundle at `PlugIns/BootstrapCanaryUITests.xctest`; its
  `CFBundleIdentifier` also equals the host bundle ID and
  `XCTContainsUITests=true`.
- The host executable has **no** XCTest/XCUIAutomation load command. At runtime
  it probes the already-mounted DDI, `dlopen`s the DDI XCTest/XCTestCore
  framework and sets `XCTestBundlePath` off-main. After an explicit Start it
  enqueues exactly one `_XCTestMain(nil)` call on the **main queue**; the
  XCTest/XCUI driver requires main-thread initialization and there is no second
  initializer, retry, delay or entry call. Host rpaths include the DDI
  Framework, PrivateFramework and `usr/lib` directories, but they do not create
  a strong link.
- The test method publishes `Documents/canary/engine-ready.json` only after it
  actually enters, then a dispatch timer from that test method writes
  `engine-heartbeat.json` and `engine-heartbeat.log`. A host-side heartbeat is
  not accepted as engine evidence.
- No network listener and no automatic app activation. Only an explicit Start
  (button or `start` command) begins the one-shot engine; only an explicit
  command opens Settings or taps.

## Build

From this directory:

```sh
CANARY_BUILD_JOBS=6 bash scripts/build_canary.sh
```

The script uses `DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer`
by default, builds both targets for `generic/platform=iOS` arm64 with
`CODE_SIGNING_ALLOWED=NO`, assembles the single `Payload/BootstrapCanary.app`,
and writes an unsigned IPA plus manifest and otool/plist evidence to:

```text
../../../../Local/Artifacts/ios-bridge-20261031/canary/
```

`BootstrapCanary-unsigned.ipa` is intentionally unsigned and re-signable.
`manifest.json` records the IPA SHA-256, source SHA, source-file hashes and
verification result. `verify.txt` shows the topology/linkage checks.

## Sign (development only)

The host app uses the existing development profile and identity. The helper
first verifies that the selected identity certificate (SHA-1/SHA-256) is in the
profile's `DeveloperCertificates`, then emits **minimal** canary entitlements:
`application-identifier` (wildcard resolved to the concrete host ID),
`com.apple.developer.team-identifier` and `get-task-allow`. It deliberately
omits NetworkExtension, VPN and Keychain capabilities because this canary has
no tunnel and does not use Keychain. It signs `Frameworks` first, then
`PlugIns/*.xctest` (no separate entitlements, matching the upstream signer),
then the host app. It never creates identities or changes accounts.

```sh
bash scripts/sign_canary_ipa.sh \
  --ipa ../../../../Local/Artifacts/ios-bridge-20261031/canary/BootstrapCanary-unsigned.ipa \
  --profile "<profile-path-or-uuid>" \
  --identity "<codesign identity SHA-1 or common name>" \
  --output ../../../../Local/Artifacts/ios-bridge-20261031/canary/BootstrapCanary-signed.ipa
```

## Device use

Replace `<device>` with the paired device identifier/name and use the same
`DEVELOPER_DIR` for `devicectl`. Run these commands from the repository root.

`devicectl device install app` accepts an extracted `.app` bundle, **not** an
IPA. Extract the signed IPA first, then install the extracted app:

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer
export DEVICE="<device>"
SIGNED_IPA=Local/Artifacts/ios-bridge-20261031/canary/BootstrapCanary-signed.ipa
INSTALL_DIR=Local/Private/ios-bridge-20261031/signed-canary/install-readback
rm -rf "$INSTALL_DIR" && mkdir -p "$INSTALL_DIR"
/usr/bin/ditto -x -k "$SIGNED_IPA" "$INSTALL_DIR"
xcrun devicectl device install app --device "$DEVICE" \
  "$INSTALL_DIR/Payload/BootstrapCanary.app"
xcrun devicectl device process launch --device "$DEVICE" org.floeagent.iosbridge
```

The app shows a bilingual status page. Tap **Start one-shot engine / 启动一次性引擎**,
or send the explicit start command:

```json
{"id":"start-1","action":"start"}
```

```sh
xcrun devicectl device copy to --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier org.floeagent.iosbridge \
  --source ./command.json --destination Documents/canary/command.json
```

After the UI test method has entered, `engine-ready.json` exists. Send one
command at a time (each needs a fresh `id`):

```json
{"id":"status-1","action":"status"}
{"id":"shot-1","action":"screenshot"}
{"id":"settings-1","action":"open_settings"}
{"id":"general-1","action":"tap_general"}
{"id":"home-1","action":"home"}
{"id":"stop-1","action":"stop"}
```

Copy the command and pull the whole evidence directory:

```sh
xcrun devicectl device copy to --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier org.floeagent.iosbridge \
  --source ./command.json --destination Documents/canary/command.json
xcrun devicectl device copy from --device "$DEVICE" \
  --domain-type appDataContainer --domain-identifier org.floeagent.iosbridge \
  --source Documents/canary --destination ./canary-pull
```

If the container copy-to destination is rejected on a particular devicectl
version, copy the `canary` directory to `Documents/` instead and keep the same
relative file names.

## Reading the evidence

- `engine-ready.json`: written by the actual XCTest method; includes test name,
  host bundle ID, test bundle ID/contains-UI-tests, PID and timestamp.
- `engine-heartbeat.json` / `.log`: written by a timer started in the test
  method. Timestamps and `systemUptime` plus gaps across `home` distinguish
  scheduling from suspension. The last line is not proof that the app was
  responsive while suspended.
- `result-<id>.json`: `authoredBy: xctest-test-method`, action status, error and
  details. `host-result-<id>.json` is clearly labeled host-coordinator output
  and is not engine proof.
- `screenshot-<id>.png`: `XCUIScreen.main.screenshot()` output while another app
  is in front, if the automation session works.
- `tap_general` only taps an unambiguous exact `General`/`通用` element. It
  deliberately refuses coordinates and ambiguous matches, returning the
  candidate frames/labels instead.
- `bootstrap.log`: host/shim pre-call evidence, DDI candidates, selected runtime,
  environment variables, `bootstrap_dispatched … queue=main`, the
  `xctest_main_entry_entered main_thread=1` line and the exact
  `about_to_call_XCTestMain` line.
- `engine-test.log`: test-side log with exceptions and command stages.

The first runtime gate is the primary's: confirm testmanagerd accepts this
normal host, `_XCTestMain` runs the embedded test method, a screenshot is real,
Settings can be activated and `General`/`通用` tapped, and heartbeat behavior
across `home` is observed. A successful build or signature is not runtime proof.
A reboot/relaunch still requires the user to open the app; this canary does not
implement DDI mounting, a tunnel or reboot recovery.
