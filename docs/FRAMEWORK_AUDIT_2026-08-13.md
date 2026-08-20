# Floe Agent 框架审核报告

审核日期：2026-08-13

审核对象：Kimi 交付的 `FloeAgent/` 框架

产品名：**Floe Agent**

结论：**框架有继续开发价值，修复后可作为开发基线；不接受“M1 已完成”的原交付结论。**

## 1. 验证结论

- Swift Package 完整构建通过。
- 7 个测试 target、151 个测试全部通过。
- iOS App 使用 Xcode 27 beta、iOS 27 iPhone 17 Pro Simulator SDK 编译通过；部署目标仍为 iOS/iPadOS 26.0。
- 已确认生成后的 App `Info.plist` 包含后台任务、后台模式与最低设备能力声明。
- 本轮没有自动启动当前处于关机状态的模拟器，因此尚未完成 UI 启动、交互与运行日志验证。
- CloudKit 容器仍需在 Apple Developer 账号中创建并关联；两台真机的 iCloud/Keychain 同步尚未验证。

审核命令：

```bash
cd "/Volumes/TECLAST/IOS AI AGENT/FloeAgent"
./scripts/pin_check.sh
./scripts/local_build.sh
./scripts/gen_project.sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -quiet -project FloeAgent.xcodeproj -scheme FloeAgent \
  -destination 'platform=iOS Simulator,id=D0F2FCE9-F2FD-4D94-90C0-233DBD52F94A' \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

## 2. 已修复问题

| 级别 | 原问题 | 处理结果 |
|---|---|---|
| 高 | `SceneDelegate` 用空 `UIViewController` 覆盖 SwiftUI Window，应用可能启动白屏 | 删除错误 SceneDelegate 接管，生命周期改由 SwiftUI `scenePhase` 按窗口上报 |
| 高 | 远程工具缺少 host scope 时仍可能在完全控制模式执行 | 从已验证参数推导 host/path scope；远程风险标签但仍为 local scope 时直接拒绝 |
| 高 | OpenAI/Anthropic tool schema 被编码成 JSON 字符串，实际请求协议错误 | 改为真正 JSON object，并增加三种 wire contract 测试 |
| 高 | Anthropic `system` 消息错误放入 `messages` | 改到顶层 `system` 字段并回归测试 |
| 高 | 工具参数只检查大小，不检查合法 JSON object | 限制 64 KiB，同时拒绝非法 JSON、数组和 null 顶层参数 |
| 高 | 后台任务与 CloudKit 代码存在，但生成的 plist/entitlements 没有能力声明 | 在 `project.yml` 中声明并验证生成产物；避免 XcodeGen 覆盖手改 plist |
| 中 | iOS 26 continued processing 错用普通 `BGProcessingTaskRequest` | 改为 `BGContinuedProcessingTaskRequest`，保留系统允许的 fallback |
| 中 | iPad `List(selection:)` 在当前 SDK 下无法编译 | 改为明确的按钮选择导航结构 |
| 中 | “内存数据库”实际创建同名磁盘库，并行测试锁库 | 使用真正的 `DatabaseQueue` 内存数据库 |
| 中 | `DatabaseManager` 有 `pool!` 强制解包 | 改为显式 invariant error |
| 中 | 供应商/模型表只有 schema，没有业务 CRUD | 新增 `ModelConfigurationStore`、安全校验、UPSERT、级联删除与 4 个测试 |
| 中 | API Key 同步 opt-out 只存在内存，重启丢失 | 改为按 Keychain service 隔离的 UserDefaults 持久偏好；密钥正文仍只在 Keychain |
| 中 | CI 将 App target 错当 test bundle，revision pin 又被脚本必然判失败 | App 改为 simulator build；pin check 接受不可变 commit revision |
| 中 | 本机有 Xcode beta，但脚本因全局 `xcode-select` 指向 CLT 而跳过测试 | 脚本仅在进程内发现并使用完整 Xcode，不修改全局设置 |
| 产品约束 | 完全控制模式拦截范围过宽 | 灾难门收窄到高置信度、直接且广泛不可逆破坏；常规运维命令不拦截；补充零宽字符绕过测试 |

## 3. 本轮新增的可用基线

模型配置现在具备本地持久化闭环：

- `ProviderProfile` 和 `ModelProfile` 可新增、更新、查询、筛选和删除。
- 数据库不保存 API Key 正文，只保存 Keychain account reference。
- 公网明文 HTTP 被拒绝；本地或私网 HTTP 仍需要明确确认。
- Provider 更新不使用 `INSERT OR REPLACE`，不会意外级联删除已有模型。
- API Key 的 iCloud Keychain 同步开关可按 provider 持久保存。
- App 已声明 CloudKit container `iCloud.org.floeagent.ios`，但开发者账号侧仍需创建/勾选该容器。

## 4. 尚未完成的阻断项

以下项目意味着 M1 仍不能验收：

1. `ConfigSyncEngine` 的 `CKSyncEngineDelegate` 仍是 no-op，没有 record save/delete、变更应用、state serialization、tombstone 或离线冲突闭环。
2. 尚无 provider/model 设置 UI，也没有把 `ModelConfigurationStore`、Keychain 与 CloudKit 串到 AppModel。
3. App lock、本地认证、Files document picker、security-scoped bookmark 与协调写回仍未完成。
4. M0 的 Office、SSH 跳板机、RoyalVNC 渲染和双设备 iCloud 验证均无实测证据。
5. SSH、VNC、文档和图片模块多数仍是领域类型或 executor placeholder，不是可交付功能。
6. 尚未在已启动模拟器上做 UI smoke test；真机签名、CloudKit entitlement 和后台任务调度也未测试。
7. App Store Connect 的实际设备过滤结果仍需验证，尤其是 `iphone-performance-gaming-tier` 对 iPad 支持范围的影响。

## 5. 建议的继续顺序

1. 先完成 M0 四项技术验证，尽早暴露 Office/RoyalVNC/Citadel 的不可行风险。
2. 同时完成模型设置 UI、本地 CRUD、Keychain secret 与 CloudKit record 的端到端连接。
3. 实现真实 provider model discovery、聊天流和 tool loop，再接生产工具 executor。
4. 建立已启动模拟器 UI smoke test、真机 Keychain/CloudKit 双设备测试和 CI UI test bundle。
5. 完成以上门槛后再把状态改为 M1 complete。
