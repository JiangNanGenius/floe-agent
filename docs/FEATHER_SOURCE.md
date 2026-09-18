# Floe Agent Feather source

The source began with build172. Build191 / GitHub Beta48 uses the verified
unsigned device artifact from the same App source as internal TestFlight,
repackaged without recompiling. TestFlight uses its separate signed package.
The source update is published and verified independently of the prerelease.

The stable source URL is:

`https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`

In Feather, open **Sources**, add this URL and choose **Floe Agent**. Feather
downloads the unsigned developer IPA; use your own certificate and provisioning
profile to sign and install it. The source does not distribute certificates.
TestFlight remains a separate installation channel.

The feed uses Feather's [AltStore-compatible format](https://github.com/claration/Feather).
Its app identifier, version, build number, minimum OS and byte size come from
the actual IPA. Download URLs point to immutable GitHub release assets; the
feed includes the SHA-256 as additional metadata, without claiming that every
Feather version verifies that field. The release also supplies a checksum file.

The publisher verifies the downloaded checksum and GitHub provenance for the
exact release tag and source commit before changing the feed. It rejects draft
releases, signed distribution bundles, other app identifiers and version
rollback. The ten most recent published builds are retained. Publishing a new
GitHub app release refreshes the same source URL without rebuilding the app.

## 简体中文

Floe Agent 软件源首版为 1.7.0（172），对应 GitHub Beta 29 的 SDK 27 未签名开发者 IPA；TestFlight 使用独立的上传 SDK 签名包。

在 Feather 的「软件源 / Sources」中添加上方地址，选择 Floe Agent 下载，再使用自己的证书和描述文件签名安装。这里提供的是开发者未签名 IPA，TestFlight 是独立渠道。

版本、构建号、最低系统和文件大小从实际安装包读取；发布前核对校验和及构建来源。以后更新沿用同一个源地址，保留最近十个已发布构建。

## Build191 recovery provenance / 恢复来源

Build191 pins App source `715cbc42e9402cf5ca691291fed5c201e61cf222` and packaging controller `3102b37924861b2745742a0212d3c044824cb694` separately. The publisher verifies attestations for both the IPA and `BUILD191-RECOVERY-PROVENANCE.json`, then matches the pinned source run, original artifact digests, controller run and IPA hash. The trust entry is explicit; a missing or invalid attestation fails publication. This does not turn the three waived UI failures into passes.

191 分别固定 App 源码与打包控制器，并验证 IPA 和恢复来源记录两份证明；再核对原始工件、运行编号与实际文件摘要。缺少或无效证明时不会发布。三项内部测试豁免仍保留，不宣称完整验收。
