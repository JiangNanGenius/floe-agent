# Android stage-release asset runbook

`prepare-stage-release.py` prepares the upload asset set for one verified
Android stage release. It is deliberately **not** a publisher and has no Git,
GitHub, signing, build, ADB or device action. The Main owner supplies the
verified source/qualification, unused version and versionCode, package,
`android/v<version>` tag, formal signing identity, preverified APK SHA-256 and
previous-release metadata, then performs the external publication and
acceptance steps below.

The release policy is `docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md`
section 23.1.1. Android and iOS releases share a repository but not a Latest
pointer or an update path.

## 1. Inputs Main must settle first

- Exact source commit and completed stage qualification.
- A new unused `versionName` and monotonically increasing `versionCode`.
- Stable Android package identity.
- Intended formal signing certificate SHA-256. The current developer debug
  certificate is denied, even if a file is named `release`.
- A tag of the form `android/v<versionName>` (for example
  `android/v0.2.0-g02`). Do not use an iOS tag or the repository Latest.
- For a later release, all three previous-release fields: versionCode,
  signer certificate SHA-256 and package. If supplied, they are enforced.
- A formally signed APK that already went through native debug stripping
  **before** signing. Never strip a signed APK in place.

## 2. Preflight: check without writing

```sh
JAVA_HOME=/path/to/jdk \
python3 FloeAndroid/scripts/prepare-stage-release.py check \
  --apk /path/to/Floe-Android-<version>-full-arm64-v8a.apk \
  --apksigner /path/to/android-sdk/build-tools/<ver>/apksigner \
  --aapt2 /path/to/android-sdk/build-tools/<ver>/aapt2 \
  --expected-sha256 <preverified-sha256> \
  --package com.floe.agent.full \
  --version-code <versionCode> \
  --version-name <versionName> \
  --tag android/v<versionName> \
  --cert-sha256 <formal-signer-cert-sha256> \
  --source-commit <40-or-64-hex-commit> \
  --min-sdk <minSdk> \
  --target-sdk <targetSdk> \
  --maturity prerelease \
  [--source-repository OWNER/REPO] \
  [--native-manifest /path/to/native-manifest.json] \
  [--previous-version-code <n> \
   --previous-cert-sha256 <sha256> \
   --previous-package com.floe.agent.full \
   --previous-release-tag android/v<older-version>]
```

`check` prints a JSON report to stdout and writes nothing. It exits non-zero
when any check fails. The report distinguishes:

- actual binary manifest/package/version/minSdk/targetSdk/ABI and signer;
- full-channel DEX markers (a positive control against Play/test artifacts);
- native ELF and zip packaging evidence;
- canonical-versus-derived native library hashes when a native manifest is
  supplied;
- Main-owned gates that this offline tool cannot prove.

## 3. Prepare the asset directory

Run only after `check` passes and the source/version decisions are final:

```sh
JAVA_HOME=/path/to/jdk \
python3 FloeAndroid/scripts/prepare-stage-release.py prepare \
  --apk /path/to/Floe-Android-<version>-full-arm64-v8a.apk \
  ...same verification arguments as check... \
  --output /path/to/upload-assets \
  --body-out /path/to/release-body.md
```

The destination must be absent or empty. The tool:

1. copies the exact input bytes into a private sibling staging directory with
   bounded buffers and a source-identity check;
2. verifies the staged copy, not a mutable source path;
3. writes exactly two upload assets:
   - `Floe-Android-<version>-full-arm64-v8a.apk`
   - `SHA256SUMS` (`<sha256>  <apk-filename>`)
4. writes `release-body.md` **outside** `upload-assets` (never upload it);
5. atomically renames the staging directory into place.

A failure preserves any existing non-empty destination and removes the
staging directory. Do not work around a failure by adding `update.json`, a
symbol archive, a debug/test APK or a native library as an asset.

### Native stripping gate

The APK must contain only the formal full-channel native set:

- no `libXCTest.so`, `libTesting.so`, `lib_TestingInterop.so`,
  `lib_Testing_Foundation.so` or `libfloe_qualification_jni.so`;
- no meaningful `.debug_*` data (empty placeholder sections are tolerated);
- stored native libraries, 16 KiB zip data alignment and 16 KiB ELF
  `PT_LOAD` alignment;
- GNU build IDs, resolvable `DT_NEEDED` entries and a `Java_`/`JNI_OnLoad`
  export in `libfloe_jni.so`.

If a stripped/derived library set is used, pass the existing canonical
`native-manifest.json` without rewriting it. The report records canonical and
derived hashes separately and sets `runtimeEquivalenceVerified` to `false`.
Main must retain the unstripped symbols privately and independently confirm
that allocated sections, build IDs, exports, dependencies and 16 KiB layout
are preserved. A checksum is not runtime-equivalence proof.

## 4. Publish (Main only)

Create an annotated tag from the exact source commit and push it. The worker
toolkit never creates tags.

Use a draft first so the two assets can be checked before publication. The
repository Latest pointer is reserved for the existing iOS stable release:
**every Android create/edit/publish, including stable, must pass
`--latest=false` explicitly.**

```sh
TAG="android/v<versionName>"
REPO="OWNER/REPO"
ASSETS=/path/to/upload-assets
BODY=/path/to/release-body.md

# Add --prerelease to the command below only for a prerelease stage.
gh release create "$TAG" \
  --repo "$REPO" \
  --verify-tag \
  --draft \
  --latest=false \
  --title "Floe for Android <versionName>" \
  --notes-file "$BODY" \
  "$ASSETS/Floe-Android-<versionName>-full-arm64-v8a.apk" \
  "$ASSETS/SHA256SUMS"
```

`--verify-tag` aborts if Main has not already pushed the tag. The tag must
point to the source commit recorded in the report; do not let `gh` create a
tag from the default branch.

Publish the draft only after the asset readback below passes:

```sh
gh release edit "$TAG" \
  --repo "$REPO" \
  --draft=false \
  --latest=false
```

Do not omit `--latest=false` and do not use `--latest=true`. Prerelease
maturity is a separate choice. Android update selection must use
`android/v` tags or a platform-filtered Android release feed; never repository
`releases/latest`, which remains the iOS installation/AltStore/Feather
pointer.

## 5. Readback after publication

Capture the pre-publication iOS Latest identity first and compare it after:

```sh
gh api "repos/$REPO/releases/latest" > latest-before.json
gh api "repos/$REPO/releases/tags/$TAG" > release.json
gh api "repos/$REPO/releases/latest" > latest-after.json
```

Verify all of the following:

- `release.json`: `draft` is false, `prerelease` matches the declared
  maturity, `tag_name` is exactly `$TAG`;
- exactly the two expected assets exist, with the expected names and sizes;
- the release tag resolves to the exact source commit. For an annotated tag,
  resolve `ref.object.type == "tag"` through
  `repos/$REPO/git/tags/<object.sha>` and compare `object.sha`; otherwise use
  the ref object SHA;
- `latest-before.json` and `latest-after.json` have the same `id` and the
  latest release is still the iOS release (not an `android/*` tag, and the iOS
  IPA/AltStore/Feather entry points still resolve);
- download each asset and verify its hash:

```sh
mkdir -p /path/to/download
gh release download "$TAG" --repo "$REPO" --dir /path/to/download
(cd /path/to/download && shasum -a 256 -c SHA256SUMS)
```

The downloaded APK SHA-256 must equal the local verified hash and the value in
`SHA256SUMS`. If it does not, stop: do not move the tag and do not publish a
different build under the same evidence.

## 6. Coverage and upgrade acceptance (Main/device)

Install the downloaded APK over the previous version on an authorized device
with the previous package and data present:

```sh
adb install -r /path/to/download/Floe-Android-<versionName>-full-arm64-v8a.apk
```

Verify the actual package/versionCode, launch, basic flow and retained data.
A different signer requires uninstalling and loses data; that is not a valid
upgrade result. Source/qualification acceptance, actual device installation,
basic usability and stage exit criteria remain Main decisions. This toolkit
does not claim G02 completion or first-release acceptance.

## 7. Failure handling

- `check`/`prepare` failure: no new asset set is committed. Fix the source or
  metadata, choose a new empty destination and rerun. Preserve the report and
  original failure.
- Draft/upload failure: recreate or repair the draft only; never move the tag
  or substitute a different APK. Reuse the exact verified artifact for a
  distribution retry.
- Latest-pointer failure: stop publication and restore/verify the existing iOS
  Latest behavior through the existing release process. Do not mark the
  Android release latest as a workaround.
- Native debug sections or test/qualification libraries: return to the build
  owner. Do not strip the signed APK, and do not suppress the check.

## 8. Updater metadata and licensing

No Android updater/feed schema is implemented at this stage. Do not invent
`update.json` or another feed contract, and do not claim automatic update
support. The Release body says manual APK installation only.

Floe is MPL-2.0. The generated body links to `LICENSE` and
`FloeAndroid/NOTICE.md` at the pinned source commit when a public source
repository is supplied. Third-party notices packaged in the APK remain there;
do not remove real redistribution obligations merely to minimize assets.

## 9. Tests

Offline unit/negative tests (no real signed APK, no device):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  FloeAndroid/scripts/tests/test_prepare_stage_release.py
```

Mocked signer/manifest facts are unit evidence only. For read-only checks of
the existing qualification artifacts, set the paths locally and expect
rejection:

```sh
export JAVA_HOME=/path/to/jdk
export FLOE_ANDROID_UNSIGNED_RELEASE_APK=/path/to/app-full-release-unsigned.apk
export FLOE_ANDROID_DEBUG_APK=/path/to/app-full-debug.apk
export FLOE_ANDROID_AAPT2=/path/to/android-sdk/build-tools/<ver>/aapt2
export FLOE_ANDROID_APKSIGNER=/path/to/android-sdk/build-tools/<ver>/apksigner
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  FloeAndroid/scripts/tests/test_prepare_stage_release.py
```

The unsigned artifact must fail signature and native-debug/test-library
checks. The debug artifact must fail debuggable/debug-certificate checks. A
real formally signed APK check and the actual download/hash/coverage-upgrade
steps remain Main gates.

## 10. Office-generation releases (pinned Office engine)

A release that embeds the pinned Collabora Office producer payload adds two
things to the above flow: the exact Office native gate and the Office
corresponding-source group. Both stay read-only/offline like the rest of this
runbook; builds, signing, publication and device acceptance remain Main's.

### 10.1 Native gate: `--office-pins`

The producer ships fourteen prebuilt arm64 libraries; twelve of them carry no
GNU build-id note, which the generic `native.build-id` gate (correctly)
refuses. `prepare-stage-release.py check|prepare` accepts
`--office-pins /path/to/core/officeengine/payload-pins.json` as the ONE
bounded exception:

- the waiver applies only to libraries whose packaged bytes hash exactly to a
  pins `libraries` entry; every other gate (stored, 16 KiB zip/ELF alignment,
  `DT_NEEDED`, debug sections, test-only) stays enforced on them;
- a pinned library missing from the APK, a hash drifting from its pin, or the
  producer's official `libc++_shared.so` appearing in the APK are hard
  failures (`office.library-missing`, `office.pin-drift`,
  `office.libcxx-official-packaged`);
- the report records the pins-file digest, every waived library and the
  producer identity copied from the pins; without `--office-pins` behaviour
  is exactly as before.

```sh
python3 FloeAndroid/scripts/prepare-stage-release.py check \
  ...same arguments as section 2... \
  --office-pins FloeAndroid/core/officeengine/payload-pins.json
```

Main confirms the recorded pins digest against the reviewed module authority
at freeze time.

### 10.2 Single combined public corresponding-source asset

The publication chain for one release is:

1. `produce-corresponding-source.py produce` — Linux-runtime offer bound to
   the final freeze commit (unchanged, proven v1.1.1);
2. the frozen private `assemble-android-corresponding-source.py` (G04 c06) —
   Linux + Sora editor combined generation, same final commit/APK binding;
3. `produce-office-corresponding-source.py produce` — adds the Office engine
   group to that combined generation **without repacking it**: the Linux/IDE
   archive/MANIFEST/SHA256SUMS are embedded byte-exact under `linux-ide/`,
   and `office/` carries the frozen module's host/JNI sources (upstream
   notices preserved), overlays plus their 142-entry binding manifest, the
   public producer manifest and payload pins (14 library hashes, the
   official-libc++ exclusion), the staging recipe, and the bilingual notices
   with the public-safe source index. `payload-pins.json` and
   `tools/README.md` travel as deterministic sanitized renderings (host-local
   staging/toolchain references dropped; every pinned value byte-preserved;
   input digests recorded in MANIFEST.json). Output: one
   `floe-android-corresponding-source-<version>.tar.gz` + MANIFEST.json +
   SHA256SUMS.

```sh
python3 FloeAndroid/scripts/produce-office-corresponding-source.py check \
  --combined-ccs-dir /path/to/combined-source \
  --office-source-dir FloeAndroid/core/officeengine \
  --release-version <version> --source-commit <final freeze commit> \
  --source-repository OWNER/REPO \
  --apk-name Floe-Android-<version>-full-arm64-v8a.apk \
  --apk-sha256 <final signed APK sha256>
# then the same command with produce --out /path/to/office-source
```

Fail-closed bindings include the pinned upstream revision/producer APK/signer
constants, the manifest↔pins↔overlays↔overlay-files↔notice-index cross-hashes
(the index's own digest is bound through its overlay add entry, never
self-embedded), the exact overlay file-set equality, the release tag/archive
URL binding (`android/v<version>` must match this run), MPL notice retention,
the credential/private-path deny scans, and the deterministic archive. The
producer binding stays the publisher's build-id/commit mechanism: no
reproducible-build or third-party attestation is claimed, and proving the
shipped APK carries these bytes stays section 2's `check` with
`--office-pins` plus Main's readback.

`check-apk.py` needs no Office change: it carries no build-id requirement.

Office-generation tests (synthetic, offline, no device/APK):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v \
  FloeAndroid/scripts/tests/test_office_release_source.py
```
