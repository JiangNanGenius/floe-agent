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
