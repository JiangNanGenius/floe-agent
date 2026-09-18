# Floe Agent 1.7.0 (191) — beta.48

## 简体中文

本次为测试版更新。内部 TestFlight 已核实 Apple VALID、未过期、Floe QA 和
IN_BETA_TESTING；中英文测试说明已保存。App 固定源码为
`715cbc42e9402cf5ca691291fed5c201e61cf222`，原始构建任务为 `35337960392`。

- 包含此前手记、Office 文档封面与全文搜索、专属助手，以及执行环境和 IDE
  云端任务状态恢复等修复。Office 封面部分是提取内容的摘要，并非原始排版渲染。
- 两个 SDK 的 App 回归各通过 204 项，iPad、iPhone 手记组件各通过 101 项。
- 三项界面自动化失败仍保留：SDK27 iPad 点击正文搜索结果超时、SDK27 iPhone
  新建按钮就绪检查超时、发布 SDK iPhone 助手重新开始按钮初始就绪检查超时。
  用户明确同意先交内部真机测试；本版本不代表完整界面验收通过。
- GitHub 安装包来自同一份未签名设备恢复工件，经校验、规范化和重新打包，
  没有重编译 App。来源记录区分原始源码、工件和打包控制器，并与 IPA 一起签署
  GitHub 来源证明。Feather 需使用用户自己的签名与描述文件，不能直接安装未签名包。

本地模型、Office/Pencil 和各类包的实际设备表现仍需测试。未提交公开 Beta
审核或正式上架；此 GitHub prerelease 不表示 Apple 已批准外部测试。

## English

This is a beta update. Internal TestFlight was verified VALID, unexpired and
IN_BETA_TESTING in the private Floe QA group; both test-note languages were read
back. The immutable App source is `715cbc42e9402cf5ca691291fed5c201e61cf222`,
original build run `35337960392`.

- Includes the preceding Notes, Office content-cover/search, dedicated assistant,
  execution-environment and IDE cloud-job recovery changes. Some Office covers
  are extracted-content summaries rather than native page-layout renders.
- Both SDK App regression suites passed 204 tests; NativeNotes components passed
  101 tests on each simulator family.
- Three UI automation failures remain: SDK27 iPad body-search result tap,
  SDK27 iPhone New-button readiness, and accepted-SDK iPhone initial assistant
  restart-button readiness. The user explicitly waived these for internal
  device testing. This is not full UI acceptance.
- The GitHub IPA reuses the original unsigned device recovery with verification,
  normalization and packaging only; the App was not recompiled. Its attested
  recovery record distinguishes App source, original artifact and packaging
  controller. Feather requires the user's own certificate/profile; the unsigned
  IPA cannot be installed directly and is separate from the signed TestFlight IPA.

Local-model, native Office/Pencil and package behavior still need device testing.
No external Beta review or production submission has been made. This GitHub
prerelease does not represent Apple approval for external testing.
