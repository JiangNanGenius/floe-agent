# Signed component embedding and public corresponding-source runbook (G03-R3)

Build interfaces and verification boundaries only. Credential values, keys and
private device data must never enter build scripts or public release material.
The release owner runs signing, artifact inspection, device acceptance and publication.

Explicit Android snapshots of shared Swift files are recorded with their source
commit and digest in [SHARED_SOURCE_PINS.json](../planning/SHARED_SOURCE_PINS.json).
Integrate and qualify the corresponding shared types and APIs before updating
these pins; keep newer independent iOS changes intact during Android delivery.

## 1. Release signing interface (outer and child, one identity)

Both `:app` and `:runtimeapp` read the identical five-entry interface from
Gradle properties or the Git-ignored `local.properties`:

| Property | Meaning |
| --- | --- |
| `floe.release.keystore` | absolute path of the approved release keystore |
| `floe.release.keyAlias` | alias of the approved signing key |
| `floe.release.storePasswordEnv` | **name** of the environment variable holding the keystore password |
| `floe.release.keyPasswordEnv` | **name** of the environment variable holding the key password |
| `floe.release.expectedCertSha256` | **public** SHA-256 digest (64 hex chars) of the approved release certificate — identity binding for the cryptographic gate below; obtainable with `apksigner verify --print-certs` on any approved candidate or `keytool` on the certificate. Never a password or key material. |

Rules (all fail-closed):

* All five must be present together, or none. Partial configuration aborts at
  configuration time and lists only the missing *entry names*.
* When configured, `signingConfigs.create("floeRelease")` is applied to
  `buildTypes.release` of BOTH modules from the same invocation — one signer
  for core and component, which is what `BundledRuntimeInstaller`'s
  certificate-equality check (`Runtime signing identity differs`) requires at
  install time.
* Password values are read only from the referenced environment variables of
  the Gradle process (Main's keychain-backed helper exports them). Nothing
  persists, prints or copies a value; the RELEASE keystore's contents are
  never read. Debug gates derive the expected signer by reading only the
  PUBLIC certificate of the configured debug identity.
* Without the interface, `:app`/`:runtimeapp` `assembleFullRelease` and
  `assemblePlayRelease` are refused by the `verifyFloeReleaseSigningIdentity`
  task — no unsigned, debug-signed or empty-cert release candidate exists.
* Debug behaviour is unchanged: the existing pinned `floe.debug.keystore`
  contract still signs every debug variant and every androidTest APK with one
  stable identity, and a fresh public checkout keeps AGP's documented default
  debug behaviour. The export/embed debug gates need **no** release secret:
  the expected debug signer certificate digest is *derived* from that same
  configured debug identity (public certificate read only).

## 2. Shared candidate version input

`gradle.properties` now carries the one release-version pair that both modules
read (with `-P` override for one invocation):

```properties
floe.version.code=8
floe.version.name=0.1.0-alpha.8
```

Choose an unused pair once before candidate qualification; the
runtime identity check compares core/component `longVersionCode` on device, so
divergent per-module constants are structurally impossible again.

## 3. Deterministic signed-child dependency graph (full channel only)

```
:app:assembleFull<Debug|Release>
 └─ verifyFloeReleaseSigningIdentity          (release: approved identity required)
 └─ :app:bundleFull<Variant>LinuxRuntime
      └─ :runtimeapp:exportFull<Variant>RuntimeApk
           └─ :runtimeapp:assembleFull<Variant>   (release guarded likewise)
```

* `ExportSignedRuntimeApk` (runtimeapp) consumes the **exact AGP variant
  artifact**: the `SingleArtifact.APK` provider from `variant.artifacts`
  supplies the artifact directory (dependency-wired), and AGP's public
  `BuiltArtifactsLoader` service reads the BuiltArtifacts metadata
  (`output-metadata.json`, version 3) to select the *single* output file. It
  refuses a missing metadata file, more than one element, a split/qualified
  element (type != SINGLE or non-empty filters), a variant/applicationId/
  versionCode mismatch, a non-`.apk` or escaping path — there is no directory
  scan, no stale pick and no filename heuristic. It then runs **real
  cryptographic signature verification** with the pinned
  `com.android.apksig` 9.4.0 `ApkVerifier` (already on the AGP buildscript
  classpath; the same library the SDK's `apksigner verify` command uses —
  digests were byte-identical to build-tools 37.0.0 `apksigner` on the
  existing alpha.7 and r1-qualification APKs). A v2/v3/v31 signature must
  VERIFY and its signer certificate's public SHA-256 digest must equal the
  expected signing identity: the release value from
  `floe.release.expectedCertSha256`, or for debug the digest *derived from the
  debug identity actually configured* (pinned `floe.debug.keystore`, else
  AGP's default debug keystore location). Only after that does it copy the
  verified bytes to `exported-runtime-apk/<variant>/runtime.apk` with
  `runtime.apk.sha256` and `runtime.apk.cert-sha256` sidecars. A structure-only
  "signing block present" check is never trusted: a forged/tampered block has
  no effect on this gate.
* `BundleLinuxRuntimeComponent` (app) consumes that staged export (never the
  raw output directory): before embedding it re-checks the signer sidecar
  against the same expected identity (one consistent signing interface for
  both modules), **re-runs the apksig verification on the exact staged bytes**,
  then re-hashes while writing the asset pair and refuses to embed unless the
  computed digest equals the export sidecar — so cryptographic verification
  strictly precedes hashing, copying and embedding, and a changed byte stream
  fails closed.
* The asset contract is unchanged for the untouched runtime authority:
  `linux-runtime/runtime.apk` + `linux-runtime/runtime.apk.sha256`;
  `BundledRuntimeInstaller`/`RuntimePeerVerifier` keep the package/channel/
  version/signer-equality checks. Nothing here relaxes them.
* Play never enters this graph: export/bundle registration is
  full-flavor-only, `REQUEST_INSTALL_PACKAGES` remains `app/src/full` only,
  and the existing channel-exclusion checks apply unchanged.

`scripts/check-apk.py` compares the Full and Play application channels. For
the Full application's embedded component, extract the exact
`assets/linux-runtime/runtime.apk`, verify its embedded SHA-256 sidecar,
and run SDK `apksigner verify --print-certs` on both APKs. Both must carry
the approved certificate and matching version; check each package identity
and non-debuggable manifest independently. `scripts/prepare-stage-release.py`
provides the formal certificate/publishing binding.

Release packaging strips debug symbols from ordinary shared libraries. Bind
each saved producer to the actual AGP merged input, then verify that NDK
`llvm-strip --strip-unneeded` produces exactly the bytes in AGP's stripped
output and the APK. Retain the unstripped producer for symbols. The PRoot
executable pair is deliberately exempt from stripping and must match its
original producer digests byte for byte. Every ELF load segment still needs
16 KiB alignment. The outer application's mapped libraries also need stored,
16 KiB-aligned ZIP entries; the runtime component uses package-manager
extraction (`extractNativeLibs=true`).

### Invocation sketch (Main)

```sh
bash <<'SH'
source FloeAndroid/scripts/env.sh
cd FloeAndroid
# debug iteration (unchanged behaviour):
./gradlew :app:assembleFullDebug :app:assemblePlayDebug --console=plain

# release candidate (identity + one version input, values never stored here;
# the two *Password env references must be exported by Main's helper first;
# floe.release.expectedCertSha256 is the approved certificate's PUBLIC digest —
# read it back from the approved certificate, never from a password store):
./gradlew \
  -Pfloe.release.keystore=/ABSOLUTE/APPROVED.Keystore \
  -Pfloe.release.keyAlias=<approved-alias> \
  -Pfloe.release.storePasswordEnv=FLOE_RELEASE_STORE_PASSWORD \
  -Pfloe.release.keyPasswordEnv=FLOE_RELEASE_KEY_PASSWORD \
  -Pfloe.release.expectedCertSha256=<64-hex-approved-public-cert-digest> \
  -Pfloe.version.code=<new unused code> \
  -Pfloe.version.name=<new unused version> \
  :app:assembleFullRelease --console=plain
SH
```

## 4. Public corresponding-source / license producer

`scripts/produce-corresponding-source.py` (offline tests in
`scripts/tests/test_produce_corresponding_source.py`) produces the minimal
reproducible public CCS archive for the shipped `libproot.so` /
`libproot_loader.so` payloads: pinned upstream PRoot-fork and talloc archives
(verbatim, hash-pinned), the original frozen `native-build/` recipe (its
recomputed `recipe_tree_sha256` must equal the retained payload producer
provenance, including when unchanged binaries reuse an earlier recipe), the single pinned EXITKILL patch, `THIRD_PARTY.md`, the retained
license texts, and optionally the allowlisted talloc relink objects.

```sh
python3 FloeAndroid/scripts/produce-corresponding-source.py check \
  --recipe-dir <frozen native-build tree> \
  --provenance <FINAL native payloads provenance.json> \
  --upstream-cache <pinned downloads dir> \
  --third-party-doc <frozen THIRD_PARTY.md> \
  --license-dir linuxruntime=FloeAndroid/core/linuxruntime/licenses \
  --license-dir commonmark=FloeAndroid/licenses/commonmark \
  --mpl-license LICENSE \
  --relink-evidence <final producer build/ export> \
  --release-version <frozen tag token> --source-commit <frozen commit>
# then the same command with produce --out <new private dir>
```

Guarantees enforced: byte-exact upstream pins, no producer-script pin drift,
no Apple/APSL code in compiled recipe inputs, credential/keystore/log/evidence names and private-key
material rejected, non-text files rejected (except the upstream archives and
allowlisted relink objects), deterministic ustar-in-gzip(mtime=0) archive,
destinations never replaced. `check` writes nothing and prints the archive
hash the run would produce; `produce` re-verifies and writes
`floe-linuxruntime-corresponding-source-<version>.tar.gz` + `MANIFEST.json` +
`SHA256SUMS`. It never fetches, builds, signs, touches Git or publishes.

## 5. Qualification and delivery boundaries

Current measured results and remaining acceptance work are recorded in
[Android progress](../../docs/FLOE_ANDROID_PROGRESS.zh-CN.md). Compilation,
unit checks, an APK build, actual device behavior and publication are separate
results. Reuse unchanged qualified components and the exact candidate artifact.

* Inspect both real APKs with the existing signature/version/channel/native
  checks. The export/embed gates do not replace the final `apksigner` read-back.
* Preserve the qualified `libproot.so` and `libproot_loader.so` bytes through
  packaging (`keepDebugSymbols`); compare the embedded component's extracted
  payload digests with the immutable producer record. Qualification-only probes
  are excluded from the component and the public shipped-payload offer.
* For unchanged PRoot payloads, use the original frozen recipe whose recomputed
  tree digest matches their provenance. A later documentation-only edit does
  not justify relabeling old provenance. Keep all original rejection evidence.
* Bind the guest resolver separately with `--guest-resolver-dir` and
  `--guest-resolver-manifest` together. Its source hashes and shipped asset
  digest must match; it is not part of the PRoot recipe tree hash.
* Execute the final CCS `check`/`produce` with the frozen release version and
  source commit. A development preflight using earlier public tokens is not a
  final archive or release acceptance result.
* Publish only the accepted Full APK, its checksum and necessary corresponding
  source/license material. Verify the immutable source tag and downloaded
  assets; keep private transport, signing files, symbols and raw logs private.
