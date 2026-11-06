# USB 串口多芯片复用与 iPadOS 分发研究

日期：2026-11-06。范围：用户要求覆盖能够支持的常见串口芯片，不局限 CH340。当前结论来自公开规范、实际源码、许可证与分发页面；已在独立模块内移植协议请求并实现 USBDriverKit 后端，没有接入正式 App、申请新权限或操作硬件。

## 结论

可以采用“公共 USBDriverKit 传输层＋按芯片族实现的协议适配”推进 M 系列 iPad 的 USB 串口支持。有可复用的通用驱动/IPC 示例和多芯片协议源码，尚未找到一个已核验、可直接集成的多芯片 iPadOS 串口完整成品。已有 USB 串口 App 上架只能证明分发路线存在，不能证明 Floe 已获相应权限或任意芯片已经兼容。

## 复用候选

| 来源 | 实际可复用部分 | 许可与边界 |
| --- | --- | --- |
| [Apple DriverKit 与客户端示例](https://developer.apple.com/documentation/driverkit/communicating-between-a-driverkit-extension-and-a-client-app) | DriverKit extension、user client 和客户端通信的官方基线 | 优先采用公开 API；正式复制前随下载包核对示例许可证。不是现成 USB 串口芯片驱动。 |
| [usb-serial-for-android](https://github.com/mik3y/usb-serial-for-android/tree/4cb9e82cdcfa095eb2fe0b0bea9605f50bd8e2f2) | CDC-ACM、FTDI、CP210x、CH34x、PL2303 的初始化、控制请求、波特率、流控和设备匹配 | 已读取 [MIT 许可证](https://github.com/mik3y/usb-serial-for-android/blob/4cb9e82cdcfa095eb2fe0b0bea9605f50bd8e2f2/LICENSE.txt)。可作为协议移植依据并保留版权/许可；Java Android USB Host 层不能直接用于 iPadOS。 |
| [RTL-SDR-USB-iPadOS](https://github.com/arvedviehweger/RTL-SDR-USB-iPadOS/tree/eaee9a22a5458e148f5d871bd0a99008897f0763) | 公开 USBDriverKit 控制/批量传输、驱动与 App IPC、资源生命周期的实际工程 | 根许可 Apache-2.0，需保留 LICENSE/NOTICE 并逐文件核对上游许可。它驱动 RTL-SDR，不是串口驱动；不能复制 Realtek entitlement 或把其运行记录当成串口验证。 |
| [FTDI 官方 D2XX](https://ftdichip.com/cn/drivers/d2xx-drivers/) | 官方索引目前列出面向 M 系列 iPad 的 DriverKit beta，需联系厂商 | 是二进制/厂商授权候选，未取得包、未核对 iPad beta 的完整许可，也未验证可嵌入 Floe。仅适用于 FTDI 产品。直接打开页面返回 403，保留索引证据，不当成下载成功。 |
| [Terminal Console](https://apps.apple.com/id/app/terminal-console/id6753069550) | App Store 中的 FTDI USB 串口分发先例 | 未核实公开源码及可复用许可，不从安装包提取或复制其驱动。上架不等于第三方可以借用其分发权限。 |

两份 GitHub 源的 HEAD 通过 `git ls-remote` 固定。已进一步读取 Android 项目的 `Ch34xSerialDriver.java`、`Cp21xxSerialDriver.java`，以及 iPadOS 工程的 driver entitlement、App Info.plist、README 和 LICENSE；不是仅凭项目标题判断可用。

## 芯片族候选矩阵

下表表示工程支持目标与可移植依据，**所有行都尚未通过 Floe USB 硬件验收**。不把同一品牌或相似芯片名当成同一协议。

| 芯片族 | 当前源码依据 | iPadOS 适配要点 |
| --- | --- | --- |
| 标准 CDC-ACM；符合该接口的 CH343、CH9102、Arduino 等 | `CdcAcmSerialDriver`；上游兼容表明确列出若干此类设备 | 按实际 USB 描述符和 interface 匹配；line coding、控制线、通知与 bulk endpoints；不能据名称假设所有型号均 CDC。 |
| FT232R/H、FT2232H、FT4232H、FT230X/231X/234XD | `FtdiSerialDriver`，另有厂商 iPad beta 候选 | 控制请求、波特率、每 USB 数据包状态前缀、多接口/多端口；各族分别验证。 |
| CP2102 与 CP210x | `Cp21xxSerialDriver` | 厂商控制请求、接口区分、波特率、DTR/RTS、流控与多端口。 |
| CH340 / CH341 串口模式 | `Ch34xSerialDriver` | 自定义初始化和寄存器/波特率序列；CH341 的其他工作模式不自动算串口支持。 |
| PL2303 各兼容修订 | `ProlificSerialDriver` | 按设备修订判别初始化路径和特殊控制请求，不能统一宣称所有仿制/新版芯片兼容。 |
| 其他 WCH CH34x / CH91xx、多串口芯片 | 按 CDC 描述符或相应厂商公开资料继续调查 | 不从 CH340 的成功推断整族成功；只有取得可用协议实现、实际描述符和验证证据后才进入支持表。 |

## 苹果规则与本项目取舍

1. **走公开的 iPadOS USBDriverKit。** [Apple 文档](https://developer.apple.com/documentation/usbdriverkit)明确适用于 M 系列 iPad；[SerialDriverKit](https://developer.apple.com/documentation/serialdriverkit)是 macOS 框架，不能把 macOS 虚拟串口驱动直接塞进 iPad App。普通 iPhone 或非 M 系列 iPad 不套用此路径。
2. **DriverKit 的开发可运行与分发权限分开。** 驱动需对应 DriverKit/USB transport 权限和实际匹配范围，宿主需 communicates-with-drivers；按 [Apple 申请流程](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)核对团队、App ID、driver ID、VID/PID 和分发 profile。当前未查看或改动 Floe 账户权限，不能宣称已经具备。
3. **驱动随已签名 App 分发与更新。** [Apple WWDC](https://developer.apple.com/videos/play/wwdc2022/110373/)明确支持通过 App Store 分发 App 和驱动；不下载额外可执行驱动、不使用私有 USB 接口、越狱或开发期安全绕过作为用户方案。用户按系统设置启用驱动。
4. **不照搬音频保活。** RTL-SDR 工程有音频背景模式和 `BackgroundAudioKeeper`。真实电台音频与普通串口传输用途不同；Floe 串口不能借音频常驻来保持会话。[审核规则 2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements)要求背景服务用于其适用用途。USB 拔出、App 失活和驱动版本变化均须正确结束或恢复连接。
5. **记录可见，数据与许可明确。** 收发记录、AI 分析、保存/导出遵循已经确认的权限、上限和凭据保护。[规则 2.5.1/2.5.2/2.5.14 与 5.2](https://developer.apple.com/app-store/review/guidelines/)分别涉及公开 API、包内代码、活动记录和第三方权利；保留所用 MIT/Apache 文件与 NOTICE，不复制无授权的商业驱动或产品界面。
6. **真实支持与审核说明对齐。** 只按实际可用的平台、芯片与端口能力开放；送审时说明驱动用途、启用方式、所需硬件与验证路径。不把“同类 App 已上架”写成 Apple 对 Floe 或本实现的批准。

## 本轮独立代码

`FloeAgent/Modules/FloeToolbox/` 已加入下列实验性源码：

- CDC-ACM、FTDI、CP210x、CH34x 的控制请求/波特率/格式设置和 FTDI 状态字节剥离。
- PL2303 legacy、HX、TA/TB、HXN 的修订分类及不同初始化/波特率计划；需要描述符和必要探测结果，不能仅凭 VID/PID 猜测。未知修订明确返回不支持。
- `USBSerialConnection` 与其他串口传输共用上层合同；未连接、禁用驱动、配置失败、短写、超长响应与关闭后返回均通过错误结束。
- 原创公开 USBDriverKit C++ 控制/批量传输后端；检查指针、缓冲区、长度与超时，串行处理传输/解绑并释放对象。它不是已签名或可安装的完整 `.dext`；R4已增加原创driver service、独占IOUserClient、严格ExternalMethod和版本化小包IPC，以及异步IOKit宿主通道；仍未增加正式App驱动target、签名或系统启用流程。
- Android 上游固定到上述提交，已保留完整 MIT 许可证及逐来源 NOTICE；不依赖 Android 运行时，不打包 RTL-SDR 二进制、音频保活或其 entitlement。

R4新增资格：以Xcode27.2（27B52）实际SDK运行iig，生成driver/user-client源码并完成arm64 DriverKit27对象编译（含真实后端与IPC C层，`-Wall -Wextra -Werror`）；IPC/描述符解析通过150,000次ASan/UBSan随机输入。较早DriverKit部署目标、完整dext链接/安装、USB附件均未验收。

2026-11-06再次核对Apple[DriverKit客户端文档](https://developer.apple.com/documentation/driverkit/communicating-between-a-driverkit-extension-and-a-client-app)、[权限申请流程](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)、[iPad DriverKit分发说明](https://developer.apple.com/videos/play/wwdc2022/110373/)及[审核规则](https://developer.apple.com/app-store/review/guidelines/#software-requirements)。路线允许App Store分发，仍需Floe自身匹配的driver/App权限、包内签名和系统启用；没有申请/修改团队权限，不保证审核通过。

本阶段接受标准按用户最新要求收窄为**代码、真实对象编译、边界和错误路径验证**。USB 硬件测试交给用户，不保证具体芯片或设备兼容，也不把自有硬件实测作为本轮等待门槛。源码中的芯片候选匹配不等于已验证可用，常见芯片的特殊版本、流控和复合接口仍需继续按反馈适配。代码验证不能给出 App 绝对不会闪退的保证。

TCP/UDP/蓝牙、Modbus、WS、MQTT、终端/VNC/浏览器及其余工具箱范围继续按[收件清单](FLOE_TOOLBOX_PREDEVELOPMENT_INVENTORY.zh-CN.md)推进。USB 不替代这些条目，也不扩大本轮签名、主 App 接入或发布权限。
