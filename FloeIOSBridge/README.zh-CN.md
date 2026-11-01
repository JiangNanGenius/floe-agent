# Floe iOS Bridge

独立的 iPhone、iPad 本机自动化桥，通过一个通用 IPA 安装。包内包含原生设置界面、本机开发隧道、共享服务核心与自动化引擎，兼容 iOS/iPadOS 26 及以上。本轮不接入主 Floe App。

源码检查、App 编译、签名安装、真机行为和公开下载分别记录。可用安装包与各版本的验收范围请查看[版本中心](https://www.floe-agent.com/releases?platform=ios-bridge)；[历史原型记录](Qualification/RECOVERY_GATE.md)不能替代其他安装包的验收。

[English](README.md) · [安装与使用](INSTALL.zh-CN.md) · [Install and use](INSTALL.md)

## 使用

首次签名、安装和开发配对可使用电脑。此后在设备上打开 Bridge 并启动服务；重启后先解锁，再打开 Bridge。日常不需要额外的运行辅助 App。签名过期、开发配对失效等情况可能仍需电脑处理；Bridge 不在 App 内登录 Apple ID 或签发证书。

主要供同一台设备上的客户端连接：

- `http://127.0.0.1:8200`
- `http://[::1]:8200`

每个新客户端都须在 Bridge 内确认配对。局域网访问与同网 Bonjour 发现分别开启，默认均关闭，不提供点对点发现。本机隧道仅路由开发服务地址，不添加普通上网默认路由或替换 DNS。开发镜像按需下载或导入，不随 IPA 分发。

1.0 范围包含点击、滑动、输入、应用切换、读屏/OCR、截图、实时视频和浏览器遥控。实际能力以 `/schema` 为准；不支持的系统或私有功能会明确返回错误。第三方 App 密码输入须为客户端单独授权，默认关闭；设备密码和系统鉴权始终由用户在设备上完成。

## 协议与客户端

`/pair`、`/rpc`、`/schema`、`/skill`、`/stream`、`/remote` 共用服务和认证状态。客户端密钥与防重放记录保存在钥匙串；撤销授权会关闭其访问和流连接。请求保留固定版本 iCTRL 的 v1 加密合同，手势坐标使用屏幕点。

详见[协议手册](Resources/BridgeRPC/SKILL.md)与[参考客户端说明](scripts/RemoteClient/README.md)。界面与引擎通过同一个 `BridgeCore` 注册表连接。开发镜像就绪后才加载 XCTest，每进程仅初始化一次。停止服务立即关闭入口并阻止后续工作；再次启动复用已初始化的引擎，初始化故障则需重新打开 App。

## 构建与签名

需要 Xcode 27.1、XcodeGen 和 Python 3。先生成并提交匹配的工程，再冻结包含完整 `FloeIOSBridge/` 的源码提交：

```sh
bash FloeIOSBridge/scripts/gen_project.sh
```

从仓库根目录构建：

```sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
bash FloeIOSBridge/scripts/build_bridge.sh --mode release --source-ref <40位提交SHA>
```

Release 模式使用已提交工程，验证依赖固定版本和源码绑定，编译 arm64 真机代码，导出 unsigned IPA、符号和私有证据；不会自动签名、安装或发布。通过 `FLOE_BRIDGE_CACHE` 指定本任务的内置 SSD 缓存，默认以 6 个编译任务串行构建。

公开产物为 `Floe-iOS-Bridge-<版本>-unsigned.ipa`、对应 `.sha256` 和最小化的 `-public.json`。真机验收对同一份产品内容 IPA 使用 `scripts/sign_bridge_ipa.sh --mode product-qualification` 私下签名，参数见 `--help`。脚本检查嵌套签名、entitlement 和描述文件。首版要求具备 Network Extension 能力的开发签名，不保证免费 Apple ID 或任意重签工具兼容。

`qualification` 仅用于重现历史原型，不能作为发布回退；`product-qualification` 保留产品内容并允许私下签名。签名 IPA、描述文件、设备标识、配对资料、日志和符号均不得进入公开附件。

独立标签为 `floe-ios-bridge-v<版本>`。发布脚本默认只读核验；显式 `--publish` 还要求已推送的不可变标签、匹配的公开产物，以及基于实际验收的私有凭据。发布为 stable 且 `make_latest=false`，保留主 Floe 和 macOS Bridge 的发布及更新源。

## 验证与许可

针对性检查位于 `Tests/` 与 `scripts/run_core_checks.sh`，最终 App 构建和真机验收由主协调者完成。项目所有者豁免了 iPad 真机门槛：按通用目标假定兼容，不声称完成硬件验证。模拟器或组件结果不能证明开发镜像恢复、后台控制或重启恢复。

自动化和协议改编自 Apache-2.0 的 [OpenMinis/iCTRL](https://github.com/OpenMinis/iCTRL/tree/c1e4268859ba858d1579f7b846a56cb40641b7f6)，本机开发连接复用 MIT 的 `idevice`，版本固定于 `Vendor/idevice.lock.json`。保留[第三方声明](ThirdParty/iCTRL/NOTICE.md)、依赖许可与修改记录。仅在重现旧私有构建时参阅[历史原型指南](Qualification/PROTOTYPE_GUIDE.md)。
