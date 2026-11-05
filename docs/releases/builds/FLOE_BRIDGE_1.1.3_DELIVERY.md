# Floe Bridge 1.1.3（6）交付记录

日期：2026-11-05。不可变来源：`2152cb50beee793a5a9f1ec07b5767bffd34731e`，标签 `floe-bridge-v1.1.3`。

## 简体中文

- [公开下载](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-bridge-v1.1.3)已发布；没有改变主 App 的 latest 指针。
- 本地 Swift 6 编译、Developer ID 签名、公证、装订和 Gatekeeper 核验通过。公开 DMG 已独立下载，大小、摘要和来源一致，更新包 Ed25519 签名已使用既有公钥验证。
- [当前更新源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/appcast.xml)与[旧版升级地址](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/bridge-updates/appcast.xml)均已读回 1.1.3。旧地址由不可变过渡标签保留，客户端升级后使用 main；远端更新源分支已删除。
- 此版本只调整版本与更新地址，复用 1.1.2 未改动的原生窗口、配对、终端和文件传输验证；没有将其记作 1.1.3 新的屏幕控制或配对验收。
- 首轮 DMG 公证流程在提交前遇到网络断开，保留失败后复用了同一份 DMG，没有重复提交已取得编号的申请。
- 本轮生成的 App、暂存件、重复包、构建缓存及私有公证传输草稿已清理。保留最终 DMG、校验文件、最少来源和必要证据；没有删除用户配对、钥匙串或工作文件。

```text
Floe-Bridge-1.1.3.dmg
bytes: 4652365
SHA-256: ee58db7ab4461a018a2d040829ce1b35243f2b408289474f98f9eeb51d70a6e8
```

## English

Bridge 1.1.3 (6) is publicly available. The signed and notarized archive passed stapling, Gatekeeper, independent download, digest, source and Ed25519 checks. Both the main feed and the immutable legacy transition URL serve this release. The old update branch was removed; upgraded clients use main. Unchanged pairing, terminal and settings evidence is reused from 1.1.2, with no new screen-control claim. Generated test apps, staging, duplicate packages, completed build caches and the private notarization transport were removed. User pairing, Keychain and workspace data remain intact.
