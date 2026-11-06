# Android Alpha28 delivery

- Public intermediate prerelease: https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.28
- Immutable source: `4751a51e2a490c65261b7596fee3db97df704fc2`; version `0.1.0-alpha.28`, code `47`.
- Full ARM64 APK: `162455553` bytes; SHA-256 `ce83f2cb8f24d7b35163997230bdfc54ae2c0b8f4513dcb9e4cdfb27beef468a`.
- Six public assets: one APK, optional Office component, Alpha27→28 delta, delta manifest, corresponding source archive and checksums. Anonymous download bytes, remote asset digests and annotated tag/source binding passed. iOS Latest remains `v1.7.74`.
- Delta production reconstructed the exact target APK and verified its signature/hash. The patch is `74006518` bytes. Cross-version full downloads bypass delta/base requirements; the related discovery/download tests passed (15 tests).
- Samsung actual use: final APK installed through development tooling with data retained; text opens in the built-in editor. Loopback graphical session connected and stopped successfully after the credential-owner repair. Ending an older retained Linux edit allowed the external-edit entry to open the installed Android text editor directly. Four VNC contract tests passed. This is not evidence of an online installation of this release, edited-file save-back or every N01–N08 capability.
- Remaining work includes Linux professional-application file save-back, smoother completion of retained edit sessions, changed-content refresh on device, actual full-download/install and further scheduled/cross-app use. Automatic unlock remains unconfigured in this Samsung round. No paid provider calls were made for this delivery.
- Cleanup retired three superseded private APKs (`487360191` file bytes) and deduplicated another identical Office split (`115007372` file bytes). Exact final assets, prior public rollback, original failures and caches with a concrete next use remain. These figures do not assert physical APFS space reclaimed.

This prerelease is an intermediate delivery. The full N01–N08 goal remains active.
