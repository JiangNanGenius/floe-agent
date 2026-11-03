# Floe Bridge 1.1.0 (3)

Released 2026-11-03 from immutable source
`518c1123652406da4e20379a0640263804a95ea9`, tag `floe-bridge-v1.1.0`.
[Download and release notes](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-bridge-v1.1.0).

- The public stable release contains the signed DMG, its SHA-256 sidecar and
  minimal source provenance. Independent public readback matched the release
  source and download digest.
- App and DMG passed Developer ID signing, Apple notarization, stapling and
  Gatekeeper checks. Sparkle rejected an intentionally invalid update signature.
- Actual Sparkle download, verification, installation and relaunch upgraded a
  task-owned test client from **1.0.99 (2) to 1.1.0 (3)** on the internal SSD.
  The relaunched App matched the release source and passed signature, stapling
  and Gatekeeper checks.
- The separate external-APFS test stalled during atomic file exchange. Its
  original evidence is retained; this release does not claim that case is fixed.

DMG: `Floe-Bridge-1.1.0.dmg`, **4,656,523 bytes**. SHA-256:
`a87e624507568c3051ee7daaf8a5406923558600150fa24226f3e4d8d042af9d`.

The [Sparkle update feed](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/bridge-updates/appcast.xml)
was published at commit `ea3812c84c19704b159921da698e72d11f93ef3b`.
The downloaded archive passed Ed25519 signature verification. The existing
`floe-bridge-v1.0.0` release and main App latest (`v1.7.65`) remain unchanged.

简体中文：Bridge 1.1.0（3）已正式公开并完成独立下载核验。内置 SSD 上实际通过
Sparkle 从测试版 1.0.99（2）下载、验证、安装并重启至本版；错误签名更新被拒绝。
App 与 DMG 的签名、公证、票据和 Gatekeeper 检查通过。外置 APFS 的原子交换
停滞仍未解决，原始证据保留；旧 Bridge 1.0 与主 App Latest 均未替换。
