# Floe Agent M0 技术验证报告

更新日期：2026-08-13
分支：`agent/m0-validation`

## 结论

M0 的可编译集成骨架已经落地，但 **M0 尚未验收完成**。CloudKit/Keychain、SSH、VNC 与文档安全写回均已有真实实现和 DEBUG 诊断入口；Office 引擎、双真机 iCloud、跳板机/VNC 真机链路仍需要外部环境完成实测。

不得用通用文本编辑器替代 Collabora/LibreOffice，也不得把模拟器编译成功写成最低硬件验证成功。

## 已实现

### 配置同步

- GRDB schema v2：CloudKit record 元数据、逐字段时间戳、change tag、system fields、pending save/delete 与 `CKSyncEngine` state serialization。
- `CKSyncEngine` 私有数据库 custom zone 的 save/delete/fetch/send、远端变更应用和逐字段合并。
- Provider/Model payload 放入 CloudKit encrypted fields；API key 正文不进入 GRDB 或 CloudKit。
- API key 使用同步 iCloud Keychain；关闭同步时在同步 item 与 device-only item 之间先复制验证、再切换偏好。
- DEBUG 设置页可创建、同步、刷新和删除固定测试 Provider，并显示“配置已到但 secret 未到”的 waiting 状态。

限制：`ApprovalModelSelection` 和通用 preference record type 尚未接入；CloudKit server-record-changed 的专项冲突测试仍需两台真机完成。

### SSH 与终端

- Citadel/SwiftNIO SSH 真实连接，支持直连和多跳 jump chain。
- 每一跳独立校验 host key；TOFU 首次显示 SHA-256 指纹，已知密钥变化硬拒绝；不使用 accept-anything validator。
- OpenSSH host-key fingerprint 对解码后的 key blob 计算 SHA-256。
- Password、Ed25519、P-256 与 RSA key authentication 解析。
- PTY 输出使用 `AsyncThrowingStream`，支持写入、resize、关闭。
- SSH direct-tcpip 与仅绑定 `127.0.0.1` 的本地转发器。
- DEBUG 设置页包含 jump/target 凭据、信任 sheet、PTY 输出与输入。

### VNC

- RoyalVNCKit session facade、密码认证、状态回调和两秒滑窗 FPS。
- Metal/Core Image framebuffer renderer。
- 单指点击/拖动、双指滚动和 `UIKeyInput` 键盘输入。
- VNC 只通过前述 SSH loopback forwarder 连接；不会在 iOS 端暴露公网 listener。

### 文档

- Files importer 接收 DOCX/XLSX/PPTX security-scoped URL。
- 原文件先复制到私有 working copy；保存时使用 `NSFileCoordinator` 替换，并保留失败恢复副本。
- 已加入 Collabora 固定 commit 的 fetch/build gate 和 app 内字体 entitlement。
- 当前 bridge 只负责安全文件生命周期；它不伪装成 Office 编辑引擎。

### 可重复验证环境

- `Tools/M0Lab/compose.yml` 定义 jump、private target 和 VNC 三个服务。
- 只有 jump host 的 SSH 端口对宿主机发布；target 与 VNC 位于 internal network。
- Docker 基础镜像使用 digest pin，测试 secret 仅通过运行时环境注入。

## 当前证据

| 门槛 | 结果 | 证据/限制 |
|---|---|---|
| iOS 26 deployment target，iOS Simulator arm64 编译 | 通过 | Xcode 27 beta，`generic/platform=iOS Simulator`，无签名构建 |
| iOS device arm64 编译 | 通过 | `generic/platform=iOS` 无签名构建；不等同真机运行 |
| iPhone 17 Pro Simulator 启动 smoke test | 通过 | App 进程保持 foreground-visible，无 crash/fault；CoreSimulator 截图服务在本机阻塞，未取得截图证据 |
| 完整单元测试 | 通过 | 159 项；较审核基线新增 schema/sync metadata 2、文档 1、SSH 指纹 3、known-host 2 |
| Compose YAML 与 shell 语法 | 通过 | Ruby YAML parser、`bash -n` |
| Docker Compose 语义验证/启动 | 阻塞 | 本机 Docker CLI 没有 Compose plugin |
| Collabora prerequisite gate | 阻塞（预期） | TECLAST 仅约 59 GiB 可用，要求 150 GiB；另缺 autoconf、automake |
| 双真机 CloudKit + iCloud Keychain | 未执行 | 需要同一 Apple Developer/iCloud container 与两台登录 iCloud 的签名设备 |
| SSH jump + PTY 真机 | 未执行 | 需要启动 lab、Mac LAN 地址和签名设备 |
| VNC Metal/input/FPS 最低硬件 | 未执行 | 需要 iPhone 15 Pro 与 M1/A17 Pro 级 iPad |
| DOCX/XLSX/PPTX Collabora round-trip | 未执行 | Office engine 尚未构建嵌入 |

## 本机复现

```bash
cd "/Volumes/TECLAST/IOS AI AGENT/FloeAgent"
xcodegen generate --spec project.yml

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project FloeAgent.xcodeproj -scheme FloeAgent \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/floe-m0-derived CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFTPM_NO_SANDBOX=1 swift test --disable-sandbox

scripts/collabora_m0.sh --check
```

有 Docker Compose plugin 后：

```bash
docker compose -f Tools/M0Lab/compose.yml up --build
```

## 完成 M0 所需操作

1. 为 Collabora build root 提供至少 150 GiB 可用空间，安装 autoconf、automake，并执行 `scripts/collabora_m0.sh --build`。
2. 将官方 iOS engine/module 作为窄适配层接入 `DocumentEngineBridge`，在签名真机验证代表性 DOCX/XLSX/PPTX 的修改、保存、关闭和重开。
3. 在 Apple Developer 账号创建并关联 `iCloud.org.floeagent.ios`，用两台真机验证 create/update/delete、离线合并、secret 延迟与同步 opt-out。
4. 安装 Docker Compose plugin，启动 lab；在真机诊断页验证 jump host、PTY resize/长输出、host-key mismatch 与断线。
5. 在最低硬件验证 VNC 30 分钟稳定性、触控/键盘、分辨率变化、FPS、内存与温升。
