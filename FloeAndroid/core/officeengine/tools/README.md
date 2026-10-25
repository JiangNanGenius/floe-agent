# Office engine payload producer inputs

This directory contains the reproducible public inputs for staging the pinned
Office producer payload (assets + prebuilt arm64 native libraries) from the
signed publisher APK:

- `../producer-manifest.json` — canonical public manifest: producer
  source/artifact identity (repository revision, APK URL, whole-APK SHA-256,
  pinned signer certificate SHA-256) and the exact per-file `bytes` +
  `SHA-256` record of all 5291 selected files (5276 assets + 15 native
  libraries, 305,107,165 bytes). It is deterministic: it contains no
  timestamps, host paths or other environment-specific metadata, so its
  SHA-256 is stable and can be pinned.
- `prepare_payload.py` — standard-library-only stager/verifier (see below).

Module pin authority lives in `../payload-pins.json`. Both this tool and
Gradle require the canonical producer manifest digest to match
`payload.manifestSha256` before trusting its records. An explicit
`--manifest` path does not bypass that pin. The tool never rewrites pins.
The pinned record preserves every original file identity while excluding
host paths and timestamps.

## Fresh-source staging recipe

1. Obtain the byte-exact signed publisher APK yourself and record its provenance:
   - publisher: Collabora Productivity Ltd. — *Collabora Office Mobile*
     26.04.4.2 (code 937, arm64-v8a)
   - official URL (pinned in `producer-manifest.json` → `artifact.url`):
     `https://www.collaboraoffice.com/downloads/fdroid/repo/collabora-office-mobile-26.04.4.2-937-release-arm64-v8a-2026-10-05.apk`
   - expected whole-APK SHA-256:
     `79e72f810d711706d205a9ff457b4bb830c607a2b988cf44246829ec4593c393`
   - expected pinned signer certificate SHA-256:
     `573258c84e149b5f4d9299e7434b2b69a8410372921d4ae586ba91ec767892cc`
   - producer source revision: `2333344185931274f9c49d6c12a408cefcef6844`
     (branch `distro/collabora/co-26.04-mobile`, no release tag exists; cite
     the 40-character revision)
2. Run the stager (it never downloads; you supply the APK explicitly):

   ```sh
   python3 core/officeengine/tools/prepare_payload.py \
     --apk /path/to/collabora-office-mobile-26.04.4.2-937-release-arm64-v8a-2026-10-05.apk \
     --output /path/to/new-owned/staged-payload
   ```

   The tool: hashes the whole APK and compares it to the pin; verifies the
   APK signature with `apksigner` and requires exactly the pinned signer
   certificate; checks the embedded `buildid` matches the pinned revision;
   validates every archive member (canonical names, no duplicates, no
   symlinks, bounded sizes/counts/total); hashes every manifest-listed member
   against the manifest; then streams only the manifest-listed files into a
   new directory `<output>` via a temporary `<output>.partial` that is
   verified and atomically renamed — an existing `--output` is never
   overwritten or deleted, and a failed run leaves no partial tree.

   `apksigner` comes from Android SDK build-tools (37+ used for the pinned
   artifact). Discovery order: `--apksigner`, `$ANDROID_SDK_ROOT`,
   `$ANDROID_HOME`, the repository toolchain
   (`$ANDROID_HOME/build-tools/<version>/apksigner`),
   then `PATH`. Pass `--java-home` if your `apksigner` needs a specific JDK.

3. Verify an existing staging tree (read-only; never writes):

   ```sh
   python3 core/officeengine/tools/prepare_payload.py --check /path/to/staged-payload
   ```

   Reports per-file size/SHA-256 verification against the manifest, plus any
   missing/corrupt/symlinked/extra files. Exit 0 only when every manifest file
   verifies and no symlinks are present.

## Selection policy

The manifest stages **all 15** native libraries listed by the producer,
including the official `libc++_shared.so`. The Gradle module selects the 14
packaged libraries itself and deliberately excludes the official libc++ (the
app ships its own), so the producer manifest must not hide that file — no
pin weakening. Nothing else is excluded: the staged tree is bit-identical to
the producer's payload for every listed path.

## Provenance and limits

- The pinned APK's embedded build id (`buildid=2333344185` in
  `assets/program/versionrc`) matches the first 10 hex of the pinned source
  revision — this is the producer's own mechanism, not an attestation; there
  is no reproducible-build proof.
- This tooling stages inspected inputs only. It does not build the engine,
  install anything, grant permissions, or prove Floe embedding, native
  loading or rendering.
