# Embedded Office producer, source and delivery boundaries

The fixed producer is Collabora Office Mobile **26.04.4.2 / 937**, arm64-v8a.
`payload-pins.json` records its whole-APK SHA-256, publisher certificate,
immutable source revision, selected native library identities and manifest pin.
The source revision `2333344185931274f9c49d6c12a408cefcef6844` is the maintained
online monorepo: `engine/` contains the core, alongside `browser/` and Android
JNI/build sources. Its build-id prefix matches the publisher's build procedure;
this is not a reproducible-build or third-party attestation claim.

- [Pinned upstream source](https://github.com/CollaboraOnline/online.mirror/tree/2333344185931274f9c49d6c12a408cefcef6844)
- [Producer build recipe](https://github.com/CollaboraOnline/online.mirror/blob/2333344185931274f9c49d6c12a408cefcef6844/android/README.md)
- [Public staging recipe](tools/README.md)

## Input identity and explicit transformations

`producer-manifest.json` is a deterministic, public per-file record: all5,291
original asset/library byte lengths and hashes match the verified publisher
input. It excludes host paths and timestamps. Both the staging CLI and Gradle
check its digest against the module pin; `--check` never rewrites pins.

The Gradle producer first verifies every consumed original file. It then applies
only the source-controlled `asset-overlays.json` operations, checking original
and resulting hashes. Original `license.html` and `notice.txt` are preserved
byte-for-byte. Floe removes opaque web-branding artwork and replaces the web
branding and native widget theme with published neutral sources. Native widget
names, states and dimensions preserve the loading interface; SVG geometry and
Floe palette are provided as editable source. The local bilingual source portal
links the original notices, fixed upstream and matching Floe source archive.

Fourteen unmodified producer native libraries are packaged. The producer's
`libc++_shared.so` is deliberately excluded; Floe retains its existing pinned
runtime. Packaging preserves those verified native bytes. Unchanged Floe native
core/authority evidence belongs to its separate producer, not to this engine.

## Floe source modifications and licences

`org/libreoffice/androidlib` Kotlin hosts adapt the pinned upstream Java ABI and
retain MPL-2.0 notices. Clipboard field shapes preserve the native JNI contract.
Floe's own observer, native policy, neutral controls and overlay code carry
MPL-2.0 source notices. Original library, font and data acknowledgements remain
in the packaged upstream licence/NOTICE documents. No Apple symbol/font exports
or upstream proprietary brand artwork are included in Floe's replacements.

The matching Floe source archive contains these host sources, overlays,
manifest, observer tests and staging tool. Unmodified upstream core/frontend
and external dependency pins are linked at their immutable revision. The source
portal states producer identity without implying an official Collabora release.

## Native policy and real readiness

This producer has **no `user:` modification layer**. Writing
`registrymodifications.xcu` would not enforce a policy. Floe instead supplies
`share/registry/floe-preview-policy.xcd` in the actual `xcsxcu` layer, ordered
by dependencies after `main`, `calc` and `writer`. It locks the five verified
macro/active-content/referrer and Writer/Calc automatic-link settings, using
their distinct never-update enums. These settings are not a universal network
sandbox or an all-format external-reference verification claim.

Read-only preview additionally uses the real native view-readonly command and
an ordered reserved reply. Native shape/tile arrival, progress, skeletons and
pixel variance cannot alone grant readiness. The observer wraps only the
actual document context, verifies a successful viewport-tile draw return and
completed visible canvas pass, and fences its nonce to the live mount. Android
then checks the same surface's visual state/compositor receipt. Blank document
pixels are valid. JavaScript semantic tests are not native device evidence.

The dedicated Office process owns loading/closing. Cancellation waits for
staging quiescence; an unclean startup/close recovery preserves inputs and
reclaims only that process. No local language model, Linux/cloud preview or
external Office app is used. Editing/saving APIs are reserved for the next
stage; R1 is read-only preview. Runtime screenshots, installability, publishing
and full hardware/visual acceptance are verified separately by the release owner.
