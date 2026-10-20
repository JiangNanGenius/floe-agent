# `prepare-stage-release` parser fixtures

These are **read-only text captures** used to exercise the binary-manifest and
APK-signing parsers without requiring a formally signed release APK or a
device. They are not evidence that a real formal APK passed.

Captured on 2026-10-19 from the existing G01/G02 component-qualification
artifacts on the development host:

| File | Source | Purpose |
| --- | --- | --- |
| `aapt2_xmltree_full_debug.txt` | `app-full-debug.apk` merged manifest | exercise the debuggable/dev-package path |
| `aapt2_xmltree_full_release_unsigned.txt` | `app-full-release-unsigned.apk` merged manifest | exercise non-debuggable release metadata |
| `aapt2_badging_full_release_unsigned.txt` | `aapt2 dump badging` for the unsigned release APK | exercise package/version/ABI parsing |
| `apksigner_debug.txt` | `apksigner verify --verbose --print-certs` for the debug APK | exercise the known debug-certificate rejection path |
| `apksigner_unsigned.txt` | `apksigner verify --verbose --print-certs` for the unsigned release APK | exercise the unsigned/no-signature path |

The fixture text contains only public manifest values, ABI names and public
certificate metadata. It contains no credentials, private keys, absolute
machine paths or user data.

The tests that consume a mock signer/manifest are **unit evidence only**. The
production CLI has no switch to bypass `aapt2` or `apksigner`; a real formally
signed APK must be checked separately by Main with the installed SDK tools.
