# Floe privacy manifest closure and locale resolution (1.7.34 / 275, 2026-10-16)

Source: `v1.7.34` (frozen at the release commit). Build: 275. This record documents
what changed, what was verified locally, and what remains genuinely unverified.
Delivery (archive, signing, upload, Apple processing) is recorded separately in
[BUILD_275_LOCAL_VERIFICATION.md](../testflight/BUILD_275_LOCAL_VERIFICATION.md).

## Scope

1. **Required-reason privacy manifests.** The App bundle and the `Floe Screen
   Share` appex each carry `PrivacyInfo.xcprivacy`. Sixteen embedded frameworks
   that actually call required-reason APIs receive controlled manifests at
   packaging time (before signing) via
   `FloeAgent/scripts/prepare_app_store_bundle.py`; the controlled sources live
   under `FloeAgent/FloeApp/Resources/PrivacyManifests/` (excluded from the App
   bundle as loose resources). `awk`, `libssh2` and `llama` were audited to use
   no required-reason API and are explicitly recorded as clean; if such a
   framework starts using one, packaging fails. Manifest injection never
   changes an executable byte (verified SHA-256 before/after).
2. **Native shell/text rebuild.** `shell.framework` and `text.framework` shipped
   as pinned ios_system v3.0.2 binaries called `statfs`/`fstatfs` for mount
   flags and I/O sizes (no disk-space value, no truthful approved reason). They
   are rebuilt from the pinned upstream commit with a reviewed patch
   (`FloeAgent/scripts/privacy-rebuild/`), preserving the exported symbol set
   (130/130 and 409/409) and removing every statfs-family import. Behaviour
   differences are recorded in
   [ARCHITECTURE_LOCAL_SHELL.md](../../ARCHITECTURE_LOCAL_SHELL.md): `find
   -fstype` reports unsupported, `wc` still counts real bytes, `tail` follow
   polls. The Linux guest tools are untouched.
3. **Locale resolution.** `FloeL10n` no longer reads
   `UserDefaults.globalDomain` (UserDefaults reasons CA92.1/1C8F.1 exclude
   system-written values). It uses public `Locale.preferredLanguages` for the
   OS language and `Locale.current.region` for the OS region, keeping language
   and region independent; system-following paths clear this app's
   `AppleLanguages` override first.
4. **Storage volume gate.** `StorageExtentAccounting` replaces `fstatfs` with
   public `URLResourceValues` (`volumeSupportsFileCloning` + sparse + zero
   runs); a volume that does not answer the capability set stays
   `.unsupported`. Measured APFS behaviour is unchanged.
5. **Feedback field.** Feedback image attachments now use the `screenshots`
   multipart field name matching the current feedback service contract.
6. **App privacy disclosure.** `NSPrivacyCollectedDataTypePerformanceData`
   (AppFunctionality / not linked / not tracking) is added to the App manifest
   to match the published App Store Connect answers; the Screen Share manifest
   drops the DiskSpace entry because FloeCore no longer uses that API category.

## Verification (local, 2026-10-16)

| Check | Command / artifact | Result |
| --- | --- | --- |
| Packaging + privacy tests | `python3 FloeAgent/scripts/tests/test_app_store_bundle.py` | 20/20 pass (11 existing + 9 new: unknown framework, undeclared use, injection hash invariance, rebuild substitution + ABI, hash/reason rejection, key-string detection) |
| Manifest lint | `plutil -lint` on all 13 controlled manifests | all OK |
| Rebuild determinism | `FloeAgent/scripts/privacy-rebuild/rebuild_shell_frameworks.py` + `PROVENANCE.json` | upstream commit, patch hash, pre/post file hashes, export sets, statfs denylist all verified |
| Rebuilt framework symbols | `nm -u`, `dwarfdump --uuid` | shell UUID `68693E63-E38F-3DB1-9B2D-2FA782E1EB3C`; text UUID `BD1169FD-7FB2-3F84-B5E0-F4492A32340D`; dSYMs retained with matching UUIDs |
| FloeCore locale tests | `swift test --filter FloeL10nTests` (FloeCoreTests) | see delivery record — run against this source |
| Storage-affected tests | `swift test --filter StorageExtent` and App-host storage suites | see delivery record |
| Full App compile | local Xcode 27.0 (27A266a) Release device archive | see delivery record |

## Recorded limitations (not hidden)

- Apple lists `getattrlist` under both FileTimestamp and DiskSpace. Floe's call
  sites read file metadata (clone/private size, directory link counts) and are
  classified as FileTimestamp. If Apple's static scan also treats the symbol as
  DiskSpace, the appex declares no reason for it (there is no truthful
  DiskSpace reason for this use); recorded rather than invented.
- `files.framework` keeps `statfs` calls that do not derive disk space (Xsan
  preallocation, `rm` I/O size, `du` devfs check, `mv` mount point). Only the
  real `df`/`stat -f` display path is anchored to reason 85F4.1. A "zero statfs"
  rebuild of `files` was deliberately not performed in this minimal round.
- Only the device slice of `shell`/`text` was rebuilt; Simulator builds still
  use the pinned binaries (no effect on the App Store archive).
- Component and independent-harness results do not replace physical-device
  acceptance; the Simulator language gate is recorded in the delivery record.
