# Optional iPad USB driver packaging / 可选 iPad USB 驱动打包

This is an opt-in **source configuration**, outside the normal five-bundle App
project. It does not build, sign, install or enable a driver. Neither an
entitlement plist nor a generated project proves a distribution grant/profile.

这是独立的可选源码配置，不接入默认五 bundle 发布工程，不构建、签名、安装或启用驱动。
生成 entitlement 文件或工程不表示已经取得团队分发权限或有效 profile。

## Review an unconfigured driver target / 检查未配置的独立 target

Run from the repository root, using a **new** private output directory:

在仓库根目录运行，输出必须是新的私有目录：

```sh
python3 FloeAgent/Modules/FloeToolbox/DriverKit/Packaging/prepare_usb_driver.py \
  --app-root FloeAgent \
  --output Local/Private/usb-driver-review
mkdir Local/Private/usb-driver-review/project
xcodegen generate \
  --spec Local/Private/usb-driver-review/driver-project.json \
  --project-root FloeAgent \
  --project Local/Private/usb-driver-review/project
```

The empty default emits a standalone DriverKit target, an empty personality list,
driver entitlement candidates, and a copy of the real App entitlements with the
iPad driver-communication key. It emits **no App overlay**. Source and existing
entitlement files are preserved. Target generation includes both `.iig` sources
so Xcode's built-in IIG rule also compiles their generated class implementations.

默认清单为空，只生成独立 DriverKit target、空匹配项、驱动 entitlement 候选，以及保留
原配置的宿主 entitlement 副本，**不生成 App 接入 overlay**。现有源码和 entitlement
不变。两个 `.iig` 都加入 Sources，后续由 Xcode 内置 IIG 规则生成并编译类实现。

The driver uses the existing object-qualified **DriverKit 27.0** minimum with
the actual DriverKit SDK and arm64. XcodeGen's `platform: macOS` is its DSL
workaround; `SDKROOT` and `SUPPORTED_PLATFORMS` are explicitly `driverkit`.
This does not establish iOS/iPadOS 26 package compatibility. No macOS activation
or client entitlement is implemented by this iPad source checkpoint.

驱动沿用已有对象资格的 **DriverKit 27.0** 最低版本、DriverKit SDK 和 arm64。
`platform: macOS` 仅因 XcodeGen 没有 DriverKit 枚举；实际 SDK 和平台显式设为
`driverkit`。尚未证明包含此驱动的 App 可在 iOS/iPadOS 26 安装运行；本阶段也未实现
macOS 激活或客户端 entitlement。

## Explicit interface scope / 明确接口范围

Supply `--matches <file.json>` only after reviewing the real device descriptors
and intended entitlement scope. Every row requires these integer fields:

只有审定实际设备描述符及权限范围后才传入非空 `--matches`；每项必须包含以下整数：

```text
idVendor, idProduct, bConfigurationValue, bInterfaceNumber,
bInterfaceClass, bInterfaceSubClass, bInterfaceProtocol
```

There is no wildcard, first-device fallback, generic CDC match or assumed
interface/configuration default. VID/PID values must already be in the existing
Core chip-candidate table; this still does not prove hardware compatibility.
No physical-device match is supplied in this package. Tests use labeled
synthetic metadata only. The USB transport entitlement and driver personality
receive the **same exact tuples**. Third-party/all-user client access is absent.

没有通配、首设备回退、通用 CDC 匹配或猜测的接口／配置号默认值。VID/PID 必须已在
现有 Core 候选表中，但候选不等于实物兼容。本包未提供任何实物匹配清单；测试只用
明确标注的合成元数据。USB transport entitlement 与 personality 使用相同的精确组合，
不开放第三方或所有用户的 client 权限。

A nonempty list additionally emits `app-overlay.json`. It links the existing
`FloeToolboxUSB` product and embeds the independent target in
`$(SYSTEM_EXTENSIONS_FOLDER_PATH)`, with the **actual App team** resolved from
`project.yml`. Driver signing is manual and requires an explicit
`FLOE_USB_DRIVER_PROFILE_SPECIFIER`; no profile is selected or created here.
Review the overlay with `xcodegen dump --no-env --type json --project-root
FloeAgent --spec <app-overlay.json>`. Generate the full App project only in the
next staged source/metadata checkpoint: base XcodeGen plist-generation entries
can otherwise rewrite existing App/extension plists. Never use this overlay in
the current release scripts.

非空清单才额外生成 `app-overlay.json`：链接现有 `FloeToolboxUSB`，在系统定义的扩展
目录嵌入独立 target，团队从实际 App 工程读取。驱动签名采用手动配置，仍需明确的
`FLOE_USB_DRIVER_PROFILE_SPECIFIER`，本脚本不选择或创建 profile。先只用上述
`xcodegen dump` 检查。完整 App 工程生成须在后续隔离的源码／元数据 checkpoint 中
进行，避免基线的 plist 生成项回写现有文件；当前发布脚本不使用此 overlay。

## Host status and next boundary / 宿主状态和下一边界

`USBDriverPackage.inspect(in: Bundle.main.bundleURL)` inspects the actual fixed
embedded payload. It returns `notIncluded`, `unconfigured`, `invalid`, or
`bundledUnverified`; **none means a running/entitled/connected driver**. It does
not scan hardware, open an IOKit user client, record, play, or send bytes.

该只读宿主接口检查实际包内固定位置，返回“未包含／未配置／无效／包含但未验证”，
这些结果均不表示驱动已运行、已获授权或已连接，也不枚举硬件、打开 user client 或发送数据。

Next checkpoint: enumerate only this team's actual published service, validate
server/class + its real provider descriptors against the packaged exact tuples,
let the user select a registry entry, revalidate on open, and verify INFO before
configuration. Pass that real channel to the existing `USBSerialClient` and
then the existing `SerialSession`/journal/lease/receive owner. Missing service,
unsupported revision, detach, cancellation and cleanup must remain real errors.
No success or system-enabled state may be synthesized from this manifest.

下一阶段只枚举本驱动实际发布的服务，核对 server/class 和真实 provider 描述符；用户
明确选择 registry entry 后，在打开及 INFO 时重新核验，再交原 `USBSerialClient`、
`SerialSession`、journal、lease 和接收 owner。服务缺失、修订不支持、拔出、取消及清理
都须走真实结果，不能由清单生成连接成功或系统启用状态。

References: [Apple iPad drivers](https://developer.apple.com/documentation/driverkit/creating-drivers-for-ipados),
[driver matching](https://developer.apple.com/documentation/driverkit/creating-a-driver-using-the-driverkit-sdk),
[USB transport entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.transport.usb),
[XcodeGen driver fixture](https://github.com/yonaskolb/XcodeGen/blob/master/Tests/Fixtures/TestProject/project.yml).
