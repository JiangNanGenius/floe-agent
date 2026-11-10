# Floe 虚拟网卡与网络后端整体增强方案

日期：2026-11-10。状态：**网络候选已通过组件与实际 Linux 验证，待主线整合和完整 App 验收**。
基线：main `b0722808df5e006b5f035d4a2f43e2a8c1f3490e`。

已完成最终依赖包、完整引擎 30 个编译单元的 macOS、iOS device、Simulator
真实对象与静态链接，以及 SwiftPM 模块接缝、固定源码和许可证清单候选。
工具链为 Xcode 27.2（27B52）。普通驱动的实际 Linux/Node 网络流程和客体
IPv6 通信已通过。已修复大文件与小请求并发退步，以及持续控制包导致旧
bulk 完成项不归还的边界问题；最终普通驱动按原始请求顺序通过，第二轮
双栈检查也通过。完整网络 App、物理 M1 及实际 IPv6-only/DNS64 网络尚未
验收。SDK 隐私清单已独立接入，并由主线从实际 App 包读回。

## 目标与性能口径

本轮范围是整套虚拟网卡和网络后端，覆盖 TCP、UDP、DNS、IPv4/IPv6、
监听转发、校验和与分段卸载、批量收发、背压及取消生命周期。用户报告的
问题发生在 Node.js 服务已经启动后的网页访问阶段，不计入虚拟机启动耗时。

保留已经落地的 CPU 状态缓存行隔离及其原资格。宿主固定计算基准的
四线程缩放为 3.79×；物理 M4 Build 319 的 sysbench 为 2.31×。旧 Build 317
的 1.46×不再作为当前基线。这些指标均不能用作新网络能力的提速结果。
当前入口见 [ARM64 性能证据](ARM64_RUNTIME_PERFORMANCE.md)。

## 总体实现

解释器侧保留现有优化：O2 编译、预解码与线程化分发、每 hart 的 MMU 状态、
栈访问快路径、CPU 状态缓存行隔离和有界执行票据。它们已经存在，不能再次
算作新收益。先前 ThinLTO、强制内联/冷热分支及 SHA helper 的实测退步也保留。
UTM SE 的无宿主 JIT 路线可参考，但不是可直接替换本引擎的轻量补丁。

本轮优先减少网络所需的客体内核与解释执行工作。后续解释器选择应使用实际
Node 请求分别测 1/2/4 vCPU 和热点；单线程 Node、内核 I/O 与多线程 sysbench
的缩放不同。物理 M1 的前台/分屏状态、安装构建和真实页面尚未确定，不按
多线程组件的 3.79×推断页面结果，也不盲目增加默认核数。

| 路线 | 与本项目的比较及选择 |
| --- | --- |
| 继续扩建当前 usernet | 现有路径轻，但缺少成熟的乱序、流控和双栈能力；整套补齐会扩大协议维护范围 |
| libslirp 4.9.7 | 提供可嵌入的普通 Ethernet、socket 事件、定时器和端口转发接缝；选为本轮主体，接受真实 GLib 依赖与固定版本的能力限制 |
| lwIP | BSD 三条款，适合嵌入；仍需选配和验证本项目的宿主 socket/NAT、转发及生命周期适配，暂不替换已经开始核验的 libslirp 路线 |
| passt/pasta | 上游当前支持 Linux，Darwin 仍列为待办；其吞吐数据不能直接移作 iPad 证据，本轮不做大型移植 |
| UTM SE / QEMU threaded interpreter | 可参考无宿主 JIT 的实现；Floe 已有预解码、线程化分发与多核优化，换引擎须独立对照，不计为本轮网络增强的现成收益 |

比较来源：[lwIP 原始许可证](https://github.com/lwip-tcpip/lwip/blob/master/COPYING)、
[passt 上游能力与平台清单](https://passt.top/passt/about/)、
[UTM SE 实现说明](https://github.com/utmapp/UTM#utm-se)。

采用“成熟网络协议后端 + 原有 ARM64 解释器 + 完整协商的虚拟网卡快路径”。
首选候选是 **libslirp 4.9.7**，保留其 TCP/IP 协议实现，适配现有网络生命周期、
端口规则和设备输出接口。网络库与必要依赖随 App 编译打包。

libslirp 主许可证为 BSD 三条款；每文件归属及传递依赖单独保留。
GLib 是真实依赖，其许可、iOS 编译、所需源码/对象及重链接材料须随依赖包核验。
不能把只下载源码、宿主 Homebrew 库可链接或其他 App 使用过当作 iOS 可交付。

GLib 使用 LGPL-2.1-or-later。若选静态链接，交付范围还包括所用库的完整对应
源码与修改，以及使用户能够修改库并重新链接 App 的对应源码或目标文件、
构建与重链接方法；单独提供 GLib 的 `.a` 不够。Floe 当前公开仓库使用 MPL-2.0，
实施优先复用相同不可变版本的完整 App 源码及固定依赖构建流程，并核对开源
组件所需的修改和调试权利。此项须在主线组合产物上闭环，不能仅由依赖包
编译成功宣称许可交付完成。

依据：[GLib 官方许可声明](https://docs.gtk.org/glib/)、
[LGPL 静态与动态链接说明](https://www.gnu.org/licenses/gpl-faq.en.html#LGPLStaticVsDynamic)、
[Apple 标准 EULA 的开源组件条款](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/)。

固定版本的能力也按实际源码核对：4.9.7 的 `TCP_DO_RFC1323` 为 0，
TCP option 解析只处理 MSS。头文件存在窗口缩放和 SACK 常量，不代表协议已
实现这些扩展。本轮不以“完整现代 TCP 全部扩展”描述换库成果；采用其成熟
连接、重传和乱序处理，再验证事件、卸载与批量路径带来的实际改善。

| 工作包 | 实际增强 | 完成条件 |
| --- | --- | --- |
| 成熟后端与依赖 | 固定源码/哈希/许可证；macOS、iOS device、Simulator 的包内网络库 | 真实对象与链接、正确 Mach-O 平台、依赖和 API 清单；无宿主动态库混入 |
| TCP/UDP 与转发 | 用成熟协议实现处理连接、重传、窗口、乱序、UDP 映射和端口生命周期 | 双向传输原字节一致，长连接/半关闭/取消/重启与规则恢复通过 |
| DNS 与双栈 | 主机实际解析器、IPv6 路由/邻居发现及 IPv6-only/DNS64/NAT64 接缝 | 客体配置与主机出网路径均可验证，不以 IPv6 feature 位代替实际通信 |
| 虚拟网卡快路径 | TX partial checksum、RX checksum、TCPv4/v6 分段及有界批量/合并 | 只广告已实现并通过协商的能力；报文及分段重组正确，旧路径仍可工作 |
| I/O 与背压 | 完整读写兴趣、网络定时器期限、队列容量与公平恢复 | 可写事件能恢复发送；接收不可消费时不空转；饱和集合不被静默截断 |
| 协议边界 | MTU、分片、ICMP/错误反馈及解析器边界 | 合法报文正确处理、畸形输入有界拒绝；外部 ICMP 按平台实际能力报告 |

卸载设备向后端提供规范的普通 Ethernet 帧，避免后端绑定某一种 guest GSO
内存布局。接收合并必须遵守 TCP 序号、flags、头长度和协商能力，不能无条件
合并，也不能通过丢包或取消检查降低测量时间。缓冲总量和单次处理工作量有界。

保持现有默认监听范围、环境归属和权限。IPv6-only 支持还需要检查实际客体
路由与 DNS 配置；成熟库支持 IPv6 只是其中一部分。对外监听、系统路由和
平台权限不因更换库而默认扩大。

## 协同与实施顺序

1. 固定当前源码和独立候选输入，完成成熟库及传递依赖的许可和 iOS 构建验证。
2. 独立完成网卡卸载/队列候选，保持后端普通帧接口；同时收敛成熟后端、DNS、
   双栈和事件/定时器适配。候选不改动 iOS 主线正在验收的 App 源码。
3. 组合候选，做原生协议/队列/生命周期检查与实际 Linux、Node.js 前后对照。
   仅纳入已验证有效、保持原语义的实现；失败和无效实验独立保留。
4. 输出精确 BEFORE/AFTER、来源及许可证、组件证据和 App 接缝，由 iOS 主线
   串行整合、完整 App 构建、固定 iPad Simulator 验证和版本分发。

实际编译沿用共享 native 构建锁，初始 6 jobs；按测得的内存与磁盘情况调整。
构件与必要日志导出后释放锁，报告和发布不占用其他任务的编译窗口。

这已是网络子系统改动，不能沿用先前单项 checksum/POLLOUT 小修的行数估计。
最终交接分别统计第三方源码、自写适配和测试的真实改动量；成熟库提供主要
协议能力，新增代码集中在嵌入适配、设备快路径和验证。

## 验证与交付边界

当前 M5 Pro 原生组件对照使用同一 Linux/Node 20.19.2、2 vCPU、768 MiB、
相同测试驱动与请求脚本、与 App 一致的线程优先级，宿主负载约 4。服务
就绪后才开始网络计时；所有传输核对长度和独立摘要，退出时销毁虚拟机。

| 指标 | 旧后端 | 完整候选，RX GSO 关闭 | 当前结论 |
| --- | ---: | ---: | --- |
| 8 MiB 响应中位数，3 次 | 1.800 秒 | 0.815 秒 | 该组件观测约 2.21×，不是 M1 页面提速倍数 |
| 大流量客体指令 / MiB | 15.124 百万 | 7.238 百万 | 减少约 52.1%，包括 Node 和客体内核 |
| 保持连接小响应中位数 | 43.50 ms | 43.88 ms | 基本持平 |
| 12 资源，6 并发 | 0.634 秒 | 0.644 秒 | 未证明小页面提速；生产 backlog 修复后的连接均成功 |
| 大流量期间新小请求 | 16 次在下载中完成，约 30 ms | 9/10 次在下载中完成，中位 52.7 ms | 已通过独立并发活跃性检查；下载时间不同，不能比较机会数 |

RX GSO 开启的早期候选更慢，因此保持关闭。早期未修公平性的候选曾观测
0.852 秒和 5.807 百万指令/MiB；这些数字属于被拒绝的中间状态，不再用作
最终结果。完成队列窗口恢复了发送背压；持续小包时也会归还旧 bulk 尾部，
空闲时全部归还，reset 丢弃旧队列 ID。实际 DMA/used-ring 检查覆盖
8/32/64/256 队列，独立报文参考 2,637 项通过；成熟后端的 471 项组件检查
通过。可重复运行入口为 `FloeAgent/Qualification/ARM64Network/run.py`。
最终同一构建的第二轮真实 IPv6+Node 检查，有 7/8 个小请求在 bulk 活跃期间
完成。实际页面还需单独验收。

普通生产驱动的客体 SLAAC 地址经虚拟网关到原生 `::1` IPv6-only 监听服务器，
8 KiB 内容摘要一致。此处仅服务器的监听族为 IPv6，不等于宿主已接入实际
IPv6-only/DNS64/NAT64 网络；后者仍待单独验收。

- 固定同一 guest Node.js 服务：小响应、大未压缩文件、实际网页三组，分别
  比较 guest-local 与 host-forwarded 的首字节、完整响应、吞吐及重复访问。
- 记录实际安装渠道及构建号、Floe 内置预览或外部浏览器入口、前后台/分屏
  状态、线程优先级及宿主负载。源码已包含某次优化，不代表用户已安装该
  二进制；后台受系统调度限制也不能用网络吞吐结果替代解释。
- 覆盖 TCP、UDP、DNS、双栈、监听转发、MTU/分片、背压、取消、重启及描述符
  生命周期。校验和/分段用独立参考与实际生产队列验证，不靠转发成功自证。
- 保留已有 CPU 隔离与并发内存、IRQ/TLBI、停止和精确预算契约。网络计数不得
  偷改公共 ABI 的 reserved 字段含义；新接缝按现有版本契约演进。
- 本机组件/对象结果、实际 Linux 网络行为、完整 App/Simulator、物理 M1
  与 Apple 审核分别报告。尚无本轮 M1 实测，不预告提速倍数。

## App Store 实现约束

按当前苹果官方要求，使用公开 iOS API，网络依赖随签名 App 编译打包，文件和
运行状态留在既有容器/授权范围内；保持既有客体解释执行与 WebKit 路径。
依赖的主机进程执行、外部 helper、宿主 JIT、私有 API 和不适用模块必须实际
排除或禁用；不增加 TAP/VPN/NetworkExtension 权限，不关闭 TLS 校验或全局
放宽 ATS 来换速度，不延长不符合原用途的后台常驻。

IPv6-only 适用性必须验证真实路径；使用系统支持的地址解析与合成，不能把
固定 NAT64 前缀拼接当作通用方案。构建/API 核查不能承诺最终 Apple 审核通过。

实际链接的组件还引用了时钟、文件元数据及磁盘空间 API。除核对 App 现有
声明外，源 SDK 应提供自己的隐私清单；采用 `FloeARM64Engine` 的 Swift
Package 资源包携带声明，保留原有静态库字节。该资源方式已在私有 Mac
消费者运行和 iOS 消费者编译/链接中验证，清单文件已从生成包读回；最终
仍须核对完整 App 内 `FloeAgent_FloeARM64Engine.bundle` 的实际内容。
此处不增加数据收集或跟踪用途。依据：[Apple SDK 隐私清单及 Swift Package
资源规则](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)、
[Required Reason API 声明规则](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)。

参考：[App Review Guidelines 2.5](https://developer.apple.com/app-store/review/guidelines/#software-requirements)、
[Apple IPv6-only 支持说明](https://developer.apple.com/support/ipv6/)、
[libslirp 4.9.7 源码](https://qemu.googlesource.com/libslirp/+/refs/tags/v4.9.7/)、
[libslirp 许可证](https://qemu.googlesource.com/libslirp/+/refs/tags/v4.9.7/LICENSE)。
