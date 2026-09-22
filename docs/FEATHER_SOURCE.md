# Floe Agent Feather source

The source began with build 172 and republishes unsigned developer IPAs from
immutable GitHub releases; the ten most recent published builds are retained.
The current entry is **1.7.0 (build 219)** from tag `v1.7.0-beta.76`, source
commit `0b21be93`, sha256
`ef2006367ab65569210f0b98fc641ba38139608462d548395aca7c219410ca95`
(745,812,559 B). The publisher verifies the downloaded checksum and GitHub
provenance for the exact release tag and source commit before changing the
feed, and rejects draft releases, signed distribution bundles, other app
identifiers and version rollback. Build191 / GitHub Beta48 was an earlier
entry, recovered from the same App source as internal TestFlight without
recompiling; its provenance record is retained below. TestFlight uses its
separate signed package, and a Feather entry does not imply TestFlight
availability.

The stable source URL is:

`https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`

The one-tap quick add uses the official site's two stable HTTPS endpoints
(reachable from the download page at `https://www.floe-agent.com/#download`).
Each endpoint attempts the exact route below against the stable source URL
on the device, then keeps a readable fallback on screen: the copyable source
URL, an "Open app" button, the download page and GitHub releases.

- Feather: `https://www.floe-agent.com/add/feather` issues `feather://source/https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`
- AltStore: `https://www.floe-agent.com/add/altstore` issues `altstore://source?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json`

GitHub renders README links only for `http`, `https` and `mailto`; it removes
the custom-scheme `href`. The English and Simplified Chinese READMEs therefore
embed two badge images that link directly to these HTTPS endpoints, so the
quick-add flow is fully clickable on GitHub while the deep links stay reserved
for on-device use. The download page chooser routes through the same
endpoints.

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

Floe Agent 软件源首版为 1.7.0（172），当前条目为 **1.7.0（build 219）**，对应标签 `v1.7.0-beta.76`、源码提交 `0b21be93`、sha256 `ef2006…10ca95`（745,812,559 B）；172、191 等早期条目作为历史保留。源只重新发布固定的 GitHub 未签名开发者 IPA，保留最近十个已发布构建。

在 Feather 的「软件源 / Sources」中添加上方地址，选择 Floe Agent 下载，再使用自己的证书和描述文件签名安装。这里提供的是开发者未签名 IPA，TestFlight 是独立渠道；Feather 中有条目不代表测试版已在 TestFlight 可用。一键添加入口是官网两个固定的 HTTPS 端点（`/add/feather` 与 `/add/altstore`）：设备上先按上文逐字节一致的深链拉起对应 App，同时始终显示可手动复制的源地址、打开 App、下载页与 GitHub 发布页等回退内容。GitHub 会移除自定义 scheme 链接，因此中英文 README 使用两张徽章图片分别直连这两个 HTTPS 端点。

版本、构建号、最低系统和文件大小从实际安装包读取；发布前核对校验和及构建来源，并拒绝草稿发布、签名分发包、其他 bundle ID 与版本回退。以后更新沿用同一个源地址。

## Build191 recovery provenance / 恢复来源

Build191 pins App source `715cbc42e9402cf5ca691291fed5c201e61cf222` and packaging controller `3102b37924861b2745742a0212d3c044824cb694` separately. The publisher verifies attestations for both the IPA and `BUILD191-RECOVERY-PROVENANCE.json`, then matches the pinned source run, original artifact digests, controller run and IPA hash. The trust entry is explicit; a missing or invalid attestation fails publication. This does not turn the three waived UI failures into passes.

191 分别固定 App 源码与打包控制器，并验证 IPA 和恢复来源记录两份证明；再核对原始工件、运行编号与实际文件摘要。缺少或无效证明时不会发布。三项内部测试豁免仍保留，不宣称完整验收。
