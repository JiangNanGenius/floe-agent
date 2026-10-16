# Floe Agent Feather source

> 文档导航更新 / Documentation navigation updated 2026-10-05: [当前状态 / Current status](CURRENT_STATUS.md) · [中文手册](USER_GUIDE.zh-CN.md) · [English manual](USER_GUIDE.md)。本文带日期的候选、测试与交付结论保留原始适用范围，不视为当前发布状态。Dated evidence below remains scoped to its original source.

The source began with build 172 and republishes unsigned developer IPAs from
immutable GitHub releases; the ten most recent published builds are retained.
The current entry is **1.7.14 (build 255)** from tag `v1.7.14`, App source
commit `850701db34411ab87ac9788eeaaf7ea3baeea2b4`, sha256
`748b40ff148073815894723a6aecb68c878e7cb33fc734ce9b4c4bb660b64255`
(738,962,981 B). The publisher verifies the downloaded checksum and pinned
GitHub provenance before changing the feed, and rejects draft releases, signed
distribution bundles, other app identifiers and version rollback. Build191 / GitHub Beta48 was an earlier
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

The English and Simplified Chinese READMEs use app-specific [AltDirect](https://github.com/StikDebug/altdirect) HTTPS links (`r=feather` or `r=altstore`) to attempt immediate launch without the Floe website landing page. This follows the approach used by Feather's own README while keeping links clickable on GitHub. The source URL remains unchanged. The website download chooser continues to offer the HTTPS endpoints above.

In Feather, open **Sources**, add this URL and choose **Floe Agent**. Feather
downloads the unsigned developer IPA; use your own certificate and provisioning
profile to sign and install it. The source does not distribute certificates.
TestFlight remains a separate installation channel.

The feed uses Feather's [AltStore-compatible format](https://github.com/claration/Feather).
Its app identifier, version, build number, minimum OS and byte size come from
the actual IPA. Download URLs point to immutable GitHub release assets; the
feed includes the SHA-256 as additional metadata, without claiming that every
Feather version verifies that field. The release also supplies a checksum file.

The publisher verifies the downloaded checksum and GitHub provenance against
the version's pinned source and workflow controller before changing the feed.
It rejects draft releases, signed distribution bundles, other app identifiers and version
rollback. The ten most recent published builds are retained. Publishing a new
GitHub app release refreshes the same source URL without rebuilding the app.

## 简体中文

Floe Agent 软件源首版为 1.7.0（172），当前条目为 **1.7.14（build 255）**，对应标签 `v1.7.14`、App 源码提交 `850701db`、sha256 `748b40…b64255`（738,962,981 B）；172、191 等早期条目作为历史保留。源只重新发布固定的 GitHub 未签名开发者 IPA，保留最近十个已发布构建。

在 Feather 的「软件源 / Sources」中添加上方地址，选择 Floe Agent 下载，再使用自己的证书和描述文件签名安装。这里提供的是开发者未签名 IPA，TestFlight 是独立渠道；Feather 中有条目不代表测试版已在 TestFlight 可用。中英文 README 的 Feather、AltStore 图标分别通过 AltDirect 的 `r=feather`、`r=altstore` HTTPS 链接直接尝试唤起对应 App，省去 Floe 官网中转页。该方式沿用 Feather 项目 README 的做法，也兼容 GitHub 链接过滤。官网的下载菜单继续使用上文列出的 HTTPS 添加源入口。

版本、构建号、最低系统和文件大小从实际安装包读取；发布前核对校验和及构建来源，并拒绝草稿发布、签名分发包、其他 bundle ID 与版本回退。以后更新沿用同一个源地址。

## Build191 recovery provenance / 恢复来源

Build191 pins App source `715cbc42e9402cf5ca691291fed5c201e61cf222` and packaging controller `3102b37924861b2745742a0212d3c044824cb694` separately. The publisher verifies attestations for both the IPA and `BUILD191-RECOVERY-PROVENANCE.json`, then matches the pinned source run, original artifact digests, controller run and IPA hash. The trust entry is explicit; a missing or invalid attestation fails publication. This does not turn the three waived UI failures into passes.

## Build255 dispatch provenance / 发布来源

Build255 keeps App source `850701db34411ab87ac9788eeaaf7ea3baeea2b4` fixed at `v1.7.14`. The release workflow controller commit `38eee8f476e3974e33504af7088449ff51438421` is separately pinned because the packaging fix was applied after tagging. The [Feather publish run](https://github.com/JiangNanGenius/floe-agent/actions/runs/37227342812) verified the GitHub IPA hash, size, attestation, release run and retained artifact against the one-off [trust policy](../FloeAgent/scripts/feather_recovery_trust.json). The tag was not moved.

191 分别固定 App 源码与打包控制器，并验证 IPA 和恢复来源记录两份证明；再核对原始工件、运行编号与实际文件摘要。缺少或无效证明时不会发布。三项内部测试豁免仍保留，不宣称完整验收。
