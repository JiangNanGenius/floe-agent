# Floe 1.7.34 (275) — Privacy manifests, feedback screenshots and locale resolution

Release candidate. Source freeze, archive, signing, TestFlight upload and Apple processing states are recorded separately from the qualification results below.

本候选完成首轮正式审核所需的隐私清单闭环：App、Screen Share 扩展和全部嵌入 framework 都带有与真实调用一致的必需理由（required-reason）隐私清单；评审相关的语言解析改为公开 API；反馈图片字段与服务契约一致。此前 1.7.33（274）已内部可用并送 publictest1 等待审核，本版不替代其状态。

## 简体中文

- **隐私清单闭环**：App 主二进制与 `Floe Screen Share` 扩展各自携带 `PrivacyInfo.xcprivacy`；16 个真实需要声明的嵌入 framework 在打包阶段注入受控清单（FileTimestamp/UserDefaults/DiskSpace/SystemBootTime/ActiveKeyboards 按实际调用点归类），`awk`、`libssh2`、`llama` 经符号与 key 字符串审计确认无必需理由 API，不注入。未知 framework 或未声明用途一律拒绝打包。
- **语言与区域解析**：系统语言改由公开 `Locale.preferredLanguages` 读取，不再访问全局偏好域；语言与区域相互独立（例如英文(US) + 澳洲区域保持 `en_AU` 的格式），切回“跟随系统”时先清除本应用的 `AppleLanguages` 覆盖，不再继承上一次强制值。
- **反馈图片字段**：反馈表单的图片附件在 multipart 请求中使用 `screenshots` 字段名，与当前反馈服务契约一致；最多三张、尺寸与数量上限不变。
- **存储卷判定**：应用内存储计量的文件系统门控改用公开 `URLResourceValues`（克隆 + 稀疏 + 零填充三项能力同时满足）；已实测的 APFS 卷行为与数值不变，HFS+/exFAT 等不回答能力的卷保持“不支持”，不猜测、不按部分能力计算。
- **App 隐私声明**：App 清单补充 Performance Data（反馈诊断携带的真实性能摘要），与 App Store Connect 中已发布的五类数据答复一致（App 功能、不关联身份、不用于追踪）。
- **命令行为说明（与上游 v3.0.2 二进制的差异，明确记录）**：本构建中本地 shell 的原生 `find -fstype` **明确返回“不支持”并说明**（不再调用未声明 API），`wc` 仍按真实字节计数（仅内部缓冲区改为 `fstat().st_blksize`），`tail` 跟随模式统一使用既有轮询回退，`tail -F` 仍每轮重新 stat 文件名。不宣称与原二进制所有行为完全一致；Linux 客体（guest）内对应工具未修改。
- 其余移动端行为、界面与上一轮（1.7.33/274）一致；本轮不重跑付费模型与完整业务矩阵，仅执行与改动相关的定向验证。

验证边界：本轮以本地 Xcode 27.0（27A266a）完成完整 App Release 归档，并在本地 iOS 模拟器执行相关单元/UI 定向测试；组件、独立 harness、macOS 与模拟器结果分别记录，不代替真机验收。符号与哈希随冻结源码一起留存，可在不重新编译 App 的前提下复用同一精确产物完成签名与上传。

## English

- **Privacy manifest closure**: the App executable and the `Floe Screen Share` extension each carry a `PrivacyInfo.xcprivacy`; 16 embedded frameworks that actually use required-reason APIs receive controlled manifests at packaging time, with each category (FileTimestamp, UserDefaults, DiskSpace, SystemBootTime, ActiveKeyboards) mapped to a reviewed call site. `awk`, `libssh2` and `llama` were audited by symbol and key-string scan and use no required-reason API, so no manifest is injected. Unknown frameworks or undeclared API use fail the packaging step.
- **Language and region resolution**: the system language is read through the public `Locale.preferredLanguages` API instead of the global preferences domain; language and region stay independent (for example English (US) with an Australian region keeps `en_AU` formatting), and switching back to “Follow System” removes this app's `AppleLanguages` override first so a previously forced value can never leak.
- **Feedback image field**: feedback image attachments use the `screenshots` multipart field name, matching the current feedback service contract; the image count and size limits are unchanged.
- **Storage volume gate**: the in-app storage accounting now decides supported filesystems through public `URLResourceValues` (file cloning, sparse files and zero runs must all be reported); measured APFS behaviour and numbers are unchanged, and volumes that do not answer the capability set (HFS+, exFAT, …) stay “unsupported” instead of being guessed or partially counted.
- **App privacy disclosure**: the App manifest adds Performance Data (the real performance summaries carried in feedback diagnostics), matching the five data types already published in App Store Connect (app functionality, not linked, not used for tracking).
- **Command behaviour notes (recorded differences from the upstream v3.0.2 binaries)**: in this build the native local-shell `find -fstype` **reports that it is not supported** (instead of calling an undeclared API), `wc` still counts real bytes (only its internal buffer now comes from `fstat().st_blksize`), and `tail` follow mode uses the existing polling fallback on every volume while `tail -F` keeps re-stat'ing names. Behaviour is not claimed to be identical to the upstream binaries in every respect, and the corresponding Linux guest tools are not modified.
- Everything else on the mobile side matches the previous round (1.7.33/274); this round does not rerun paid-model or full business matrices, only change-scoped verification.

Qualification limits: this round used local Xcode 27.0 (27A266a) for the full App Release archive and ran the related unit/UI tests on a local iOS Simulator. Component, independent-harness, macOS and Simulator results are recorded separately and do not replace physical-device acceptance. Symbols and hashes are retained with the frozen source so the same exact artifact can be signed and uploaded without rebuilding the App.
