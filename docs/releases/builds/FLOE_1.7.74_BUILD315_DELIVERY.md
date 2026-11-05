# Floe Agent 1.7.74（315）交付记录

日期：2026-11-05。不可变来源：`da5e0631a601a7a01c5dd74ef37200fa27b08c7f`，标签 `v1.7.74`。本记录为冻结后的交付证据，不改写标签或安装包。

## 简体中文

- 减少本机运行环境计算线程的交接及无变化状态的重复唤醒。各核心数量采用相同的执行批次上限；停止、热插拔、IRQ、TLB 同步和有界预算检查保留。
- 修复部分依赖包的符号链接读写、临时目录清理及 Linux 目录删除标志转换，保留目录边界和只读保护。
- 修复助手读取 Office 页面时图像上下颠倒。原失败保留；整页及带偏移裁切的实际 App 像素回归通过。物理 iPad 的真实助手读取也返回正向图像并识别手写内容，没有修改源文档。
- Xcode 27.1（27A9275）Swift 6 完整 App／测试宿主编译及最终来源的 arm64 iOS 设备归档通过。两项 App-host 回归使用既有固定 iPad 模拟器；编译于 `10f5fc5e8` 的整个 App 树与冻结来源一致，后续差异只有工作流和文档。归档只编译一次，签名和分发复用同一份已校验产物。
- 原生正常／ThreadSanitizer 并发检查、19 项真实 9P 协议检查及实际 App 共享临时目录预检通过。此前完整 EDA 技能回归的失败仍保留；局部预检没有被算成完整技能资格，候选数据技能继续独立验收。

### 物理 iPad 性能对照

在同一台 M4 iPad Air 13、iPadOS 27.2 上，分别通过 TestFlight 安装实际 314 和 315。保持四核／1024 MiB、同一 ARM64 Linux、同一 sysbench 1.0.20 二进制和未修改脚本。每次固定总计 1000 个事件，每个线程数测三次，顺序交错；九份原始输出、事件数、哈希、在线 CPU 和结果中位数独立核验一致。

| 线程数 | 314 中位吞吐（事件／秒） | 315 中位吞吐（事件／秒） | 提升 |
| --- | ---: | ---: | ---: |
| 1 | 100.07 | 122.31 | 22.2% |
| 2 | 171.69 | 205.68 | 19.8% |
| 4 | 153.56 | 183.47 | 19.5% |

九次计算的客体计时合计由 69.513 秒降为 57.790 秒，约节省 16.9% 时间；不包含下载、安装、启动虚拟机及等待模型的时间。文件、依赖和配置保留，重复启动请求复用了已运行环境。

这是一次同设备配对、每种线程数三次的固定负载结果，不代表所有任务。315 的四线程相对单线程仍约 1.50×，没有宣称达到 3.5×；本轮改善了整体吞吐，多核相对加速比尚未提高。

### 分发和审核

- Apple：`VALID`、未过期，现有 Floe QA 为 `IN_BETA_TESTING`；实际 iPad 已安装并完成上述验收。
- 正式 App Store：撤回排队中的 314，改交 1.7.74（315），独立读回为“等待审核”，保持通过后自动发布。尚未宣称正式上架。
- 公开 TestFlight：315 提交至既有 `publictest1`，独立 GET 读回为 `WAITING_FOR_BETA_REVIEW`，仅有一次审核提交；双语测试说明及审核备注匹配。等待审核不等于公开可安装。
- [GitHub 稳定／latest 无签名安装包](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.74)已核验不可变标签、来源、真实 arm64 iOS 可执行文件、远端摘要和 latest 指针。[同一发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/42018736701)的 Feather 更新已等待完成，实际 URL、版本、来源和摘要独立读回一致。
- 原有后台音频审核视频保留，并明确说明拍摄于 308，没有冒充 315 新录制。公开 TestFlight 的 API 写备注返回 403 后，使用已登录的 Safari 完成保存、重载核对和提交，没有重复上传或重复提交。

```text
Floe-Agent-1.7.74-build315-unsigned.ipa
bytes: 821389309
SHA-256: a7f8df75aaadc904d90cd8e0d05778257b28fbb2813088d2ce23eeac51accac2
```

### 收尾

保留 315 安装包、原始 App 恢复包、全部 14 份符号及必要的 314 回滚。已核验恢复字节后清理本轮 DerivedData、重复 App／归档、传输解包目录和重复数据库副本；已消费的私有传输草稿已移除。过期 313 安装包另行退役，历史符号、来源和故障记录保留。

仓库保持唯一 main 工作副本及本地／远端 main 分支。固定模拟器和 App 测试缓存交还技能线程，用于已计划的数据技能完整验收；不停止其他任务的设备或删除其数据。Mac 临时输入源、键盘捕获设置已恢复，物理设备共享已停止，Mac Bridge／Floe 测试应用未重新安装。

## English

Build 315 reduces runtime worker handoffs and redundant IRQ wakeups, fixes symlink and directory-removal operations while retaining access boundaries, and corrects inverted Office images read by the assistant. Full Swift 6 App/test compilation, the final-source device archive, targeted canonical-iPad App tests and native concurrency/protocol checks passed. The unchanged entire App tree binds the simulator-tested source to the frozen source. Original failures remain available; the focused shared-tempfile check does not qualify the complete EDA skill.

On the same physical M4 iPad, unchanged fixed-work sysbench trials showed median throughput gains of 22.2%, 19.8% and 19.5% at one, two and four threads. Nine trials took 69.513 seconds on 314 and 57.790 seconds on 315, excluding installation, boot and model waiting. This is one matched pair with three counterbalanced repetitions per thread count. Four-thread scaling remains approximately 1.50× single-thread throughput, not 3.5×. Existing configuration, files and dependencies were preserved; a real assistant Office-image read also passed on 315.

Apple reports VALID, unexpired and available to Floe QA. Formal review now contains 315, is waiting for review and will release automatically after approval. The single publictest1 submission is waiting for Beta review, so public TestFlight installability is not claimed. The stable/latest unsigned GitHub package and awaited Feather update passed independent source, architecture, asset and digest readback. Recovery artifacts and symbols were retained before removing consumed duplicates. Only main remains; ongoing skill qualification owns its explicitly retained test cache and simulator.
