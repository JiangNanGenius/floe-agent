# Third-party components and licensing

iCTRL is licensed under the **Apache License, Version 2.0** (see `LICENSE`).

Earlier versions were released under the GNU Affero General Public License v3,
because they vendored `ldid` (AGPL-3.0) for on-device code signing. That code
has been removed, nothing in the tree derives from AGPL-licensed code any more,
and iCTRL has a single copyright holder, so it was relicensed. Copies obtained
under the AGPL remain available under the AGPL; new versions are Apache-2.0.

## Components

| Component | Upstream | License | Used for |
|---|---|---|---|
| `idevice` | [jkcoxson/idevice](https://github.com/jkcoxson/idevice) | MIT | RSD tunnel, lockdownd, image mounter — all of `iCTRLApp/DDI`'s protocol work |
| StikDebug | [StikDebug/StikDebug](https://github.com/StikDebug/StikDebug) | AGPL-3.0 | **Idea only, no code copied.** On-device DDI mounting without a privileged entitlement is StikDebug's idea. `DDIMounter.swift` is an independent implementation against the `idevice` API, whose calls any client must make in this order. |
| StosVPN / LocalDevVPN | [SideStore/StosVPN](https://github.com/SideStore/StosVPN), [jkcoxson/LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) | NOASSERTION | Invoked as a separate app (URL scheme), not vendored. Provides the `10.7.0.1` reflector that lets iCTRL reach this device's own lockdownd. |
| DeveloperDiskImage mirror | [doronz88/DeveloperDiskImage](https://github.com/doronz88/DeveloperDiskImage) | See upstream | Downloaded at runtime, not redistributed: `BuildManifest.plist`, `Image.dmg`, `Image.dmg.trustcache`. Users may supply their own copy from Xcode instead. |
| WebDriverAgent | [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent) | Apache-2.0 | **Prior art only, no code copied.** The long-lived-runner patterns (`distantFuture` run loop, failure-proof test case) follow what it established. |

## Signing

iCTRL neither signs nor installs apps. Both packages are signed and installed
with SideStore (free Apple ID) or `Scripts/sign-ipa.sh` / Xcode (paid account).

An in-app signer, and later an in-app installer, were built and removed. What
the signer ran into is worth recording, because none of it is apparent up
front:

- **Apple ID login needs anisette**, and iOS cannot produce it. There is no
  linkable ADI library on the system, and `AuthKit` only proxies to an
  entitlement-gated XPC service. Every route to a certificate therefore
  depends on a third-party anisette server seeing the fingerprint the account
  logs in under.
- **The runner is not an ordinary app.** Its `.xctest` shares the host's bundle
  identifier instead of extending it, and generic signers reject or mishandle
  that. `ldid` skips `.xctest` entirely — it recurses only into `.framework` and
  `.appex` — so the bundle installs and then fails to launch, because
  testmanagerd validates the plugin's own signature. Current SideStore signs it
  correctly; older, ldid-based releases do not.
