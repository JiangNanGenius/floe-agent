# Floe Bridge 1.1.4（7）交付记录

日期：2026-11-13。不可变来源：`773a0bce8daf8b27b43d247367341b7edce0ad05`，标签 `floe-bridge-v1.1.4`。

## 简体中文

- [GitHub 发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-bridge-v1.1.4)已公开，包含签名公证 DMG、SHA-256 校验文件与 `source.json`。[双语改动说明](../notes/FLOE_BRIDGE_1.1.4_NOTES.md)已提交。主 App 的 GitHub latest 读回仍为 `v1.8.19`。
- 复用 2026-11-12 保留的 1.1.4（7）候选原包，仅使用正式下载文件名；本次没有重新编译或签名。原构建工具链为 Xcode 27.2（27B52）及 macOS SDK 27.2，支持 arm64、macOS 15+。
- 本次逐项核对 51 个源码文件与冻结提交及当前 Bridge 源码一致。`codesign --verify --strict`、`xcrun stapler validate`、Gatekeeper 检查通过；只读挂载后验证包内 App、嵌套签名、hardened runtime、公证票据、来源及可执行文件摘要，完成后已卸载镜像。
- 三个公开附件均以匿名 HTTP 下载完整字节，与本地原件、GitHub 附件大小及摘要一致。Sparkle Ed25519 签名也已针对公开 DMG 字节验证。
- [当前更新源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/appcast.xml)已独立读回 1.1.4／build 7，下载地址、大小、架构与签名一致。原有三个更新条目保留。[旧客户端过渡地址](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/bridge-updates/appcast.xml)仍为不可变的 1.1.3；该版本使用 main 更新源，可继续发现 1.1.4。
- 复用对应源码已有的 48 项 companion 与 15 项 workspace/resolver 测试记录。本次完成分发与更新源核验，未执行实际安装、配对文件读取或视觉模型端到端验收。
- 已移除本次匿名下载的三个临时副本，逻辑大小 4,694,529 字节；清理窗口外置卷可用空间净增加 4,681,728 字节。保留原候选、符号、正式发布包及核验证据。

```text
Floe-Bridge-1.1.4.dmg
bytes: 4693845
SHA-256: 6455ce95f92ae94dfe36ac0e9a39bfb24baa05192ff2e370f1da7298d050b0bc
```

## English

Bridge 1.1.4 (7) is publicly available with its signed and notarized DMG, checksum and source metadata. The retained candidate was reused without rebuilding or signing again; its 51 source files match the frozen commit and current Bridge source. The original toolchain was Xcode 27.2 (27B52), macOS SDK 27.2, targeting Apple Silicon and macOS 15+.

Fresh checks passed for signatures, hardened runtime, stapled tickets, Gatekeeper, mounted App provenance, anonymous downloads of all three assets, hashes and the Sparkle signature over the public DMG. The live main feed serves 1.1.4 (7); existing entries and the immutable legacy-to-1.1.3-to-main upgrade path remain available. The main App's latest pointer remains `v1.8.19`.

Prior companion and resolver test evidence was reused. Installation, paired file reads and visual-model delivery were outside this distribution verification. Temporary download copies were removed; the original candidate, symbols, final package and verification evidence were retained.
