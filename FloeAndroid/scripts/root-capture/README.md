# Root capture helper build

This directory owns the only production source/build path for the Full-only
`tcpdump-v1` helper. Nothing here is used by Play.

```sh
# Build, verify, and stage the exact bytes into app/src/full:
bash scripts/root-capture/build-helper.sh --stage
```

Inputs and prerequisites:

- Android NDK `30.0.16248370` (`ANDROID_NDK_HOME` or `--ndk`).
- Official tcpdump 4.99.5 / libpcap 1.10.5 archives with the SHA-256 values in
  `licenses/root-capture/SOURCES.md` (`--sources` for an offline cache).
- Python 3 and a Bash host with curl when the archives are not cached.

The script produces:

- `build/root-capture/out/libfloecapture_helper.so` (AArch64/min28 PIE,
  16 KiB PT_LOAD alignment, stripped, no unexpected `DT_NEEDED`).
- `build/root-capture/out/helper.json` (exact digest/size/ABI/version).
- With `--stage`: `app/src/full/jniLibs/arm64-v8a/libfloecapture_helper.so`
  and `app/src/full/assets/root-capture/helper.json`.

`verify-helper.py` fails closed on wrong architecture, non-PIE, sub-16 KiB
segment alignment, RPATH/RUNPATH/TEXTREL, unexpected shared libraries, an
oversized file or a digest mismatch. `stage-helper.py` re-verifies the binary,
requires the license/notice files and writes the digest-bound manifest.

At runtime:

- The App preflights the packaged manifest against the extracted
  `nativeLibraryDir` file. Missing/invalid bytes = `helperUnavailable`.
- The root server reads the manifest and `lib/arm64-v8a/libfloecapture_helper.so`
  from the installed, signature-verified Floe Full APK and verifies SHA-256.
  It executes the package-manager extracted
  `nativeLibraryDir/libfloecapture_helper.so` only when it is under the verified
  package's own code directory and is executable; otherwise it installs the
  exact APK entry to `/data/local/floe-capture/helper/<sha256>/tcpdump`
  (root-owned 0700 ancestry, 0500 binary, `O_EXCL|O_NOFOLLOW` staging) before
  executing it. Capture output uses `/data/local/floe-capture/work`. Old fixed
  paths, writable tmp files and OEM system binaries are never accepted.
- The release packaging gate (`verifyRootCaptureHelper` in the central
  `app/build.gradle.kts` patch) rejects a Full release whose staged bytes do
  not match the manifest.

No binary, build output, source archive or generated manifest is committed to
the source tree by this lane.
