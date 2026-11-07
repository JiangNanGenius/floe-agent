# Android Alpha47 交付记录

2026-11-07，[Android 0.1.0-alpha.47](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.47) 已公开，code66，固定源码 `ad811235194e24484cc81f8ae539b0d943bce2d9`。主 APK 为 164011759 字节，SHA-256：`7a82517b224bb0679fef30f39ff4451968538e706023d3439d57fad60382a0a2`。这是中间版本，整轮 N01–N08 仍继续。

## 本包变化与验证

- Office／CAD 首次安装可选组件后，按原任务和工作区返回原文档。恢复记录由真实安装会话绑定，重开时重新核对既有任务、工作区、文件及组件；切换任务或主动导航后不恢复旧入口，不凭路径创建所有者。
- 系统安装取消与失败分别显示；修复前台恢复先于最终安装回调而丢失取消状态的竞态。Office 等实际组件就绪后才建立工作副本，取消下载不再遗留安装前的恢复记录。
- 真实 Full 生产构建和 Play Kotlin 编译通过，约 4 分 12 秒。11 项新增持久恢复／所有权回归在修复来源上运行通过，最终版本核对相同实现后复用。原生 3096 份输入不变，复用 native13；实际 58 行封装记录、签名、ARM64/JNI 及 16 KiB 核对通过，符号保留。
- 三星私有 code65 修复候选实际验证 CAD 安装重启后自动返回并显示 STL、Office 自动返回并渲染，以及 Office 下载取消后无安装前恢复副本。最终 code66 的新增实机证据是下面的在线升级，不能把私有候选证据改记为 code66 的全部组件验收。

## 三星在线升级与公开下载

三星从私有 code65 修复包，通过 App 默认更新入口发现公开47，实际选择完整包，完成下载、校验、主程序及运行环境的系统安装确认和 Play 保护扫描。两包实际版本均为66，主 APK 与内嵌运行环境的安装字节相符，原 UID 保留；重开显示“更新已安装”，原项目和聊天记录仍可见。没有通过 ADB 安装47。

公开46→47补丁为45120691字节，已经真实重建到目标 APK 摘要；本次三星使用完整包，不计为设备增量重建通过。七附件保持一份主 APK、Office／CAD 组件、增量、更新清单、校验及对应源码归档；全部匿名下载字节、标签→源码和更新发现已读回。iOS Latest 保持 `v1.7.74`。

## 已知限制与继续事项

Office 原生关闭仍可能没有明确保存回执，保守保留一份未确认工作副本；不以文件未变化推定保存成功。测试自建的三份恢复副本已从 App 清理，原件摘要不变。一个895字节合成来源文件仍被授权关联引用，保留作复现，未强行撤销其授权，不计为来源释放验收。

两次新 Ark Plan／ark-code-latest 计算器运行均保留完整回执。逐次审批场景首次点击失去旧页面引用后停止；明确选中“自动允许”的新任务实际按出1，下一次“＋”仍返回观察失效。后一动作使用了工具刚返回的新ID，距该观察约64秒，低于120秒时限；失败前没有协调者切换界面。计算未完成，不能仅归因于审批设置或时限。源码补充了不含界面内容的失效状态诊断，Release模块已编译，尚未进入47。

三星通过Floe通知内输入完成真正的Android无线配对；App实际启动UID2000的自有服务，停止后旧PID消失，再启动复用信任并产生新PID，Root保持关闭。但模型经App查询计算器进程返回0，而实机该PID仍在：服务先截取500条进程，目标位于第805条，被过早截断。后续源码已修为完整读取有字节上限的表、筛选后限制回复；4项回归和Release模块编译通过，新APK验证仍待完成。因此配对与服务生命周期已有实机证据，系统查询尚未闭环，47仍有漏报问题。

跨项目图形隔离、专业 Linux 编辑器保存、系统条件任务及其余原定场景继续逐项实测修复。只读 CAD 的实际样例证据仍限于已测格式，不扩大为全部格式或建模编辑可用。

## 清理与来源对账

本次47包收尾实测释放3459923968字节，约3.46GB：19处构建生成输出、7个已完成打包目录、6处有精确公开恢复字节的旧45安装产物及2处相同不可变组件副本。生产回执先导出；当前47、回退46、本轮code65故障候选、源码、符号、SDK／AVD和近期明确使用的缓存保留，未修改其他任务的iOS工作。历史45候选03的原ANR APK缺失仍按原更正记录保留，不用公开45替代其恢复证明。

47冻结时的iOS已提交基线为 `e4d334904ae59c17d3cf86a8e40ee0f60bf9dcc0`。交付补充期间新增 `eb3bb7bca14e3bd741782f9c9bfa4c5eedc0ee34`：45条Biology模块与6条独立资格宿主路径。此新增独立能力登记下一轮需求复核，不移动本轮N01–N08范围，不把模块／宿主结果改记为完整App验收。活跃iOS未提交修改仍归原任务，未吸收到Android修改中。

English: Alpha47 restores the originating owned document after on-demand component installation and fixes cancellation ordering and premature Office recovery staging. Relevant Full/Play compilation, 11 focused recovery tests and unchanged-native package checks pass. Samsung actually installed the public full update through the App; both code66 packages, bytes, UIDs and visible project/history retention were checked. Component behavior evidence remains bound to the matching private code65 implementation. All seven public assets were read back; the46→47 patch was locally reconstructed, while Samsung used the full download. New Calculator runs stopped on stale observations; the automatic-policy run pressed1 but did not complete1+2. Embedded ADB genuinely paired, started asUID2000, stopped and restarted with a new PID, but its process query missed a real process beyond an early500-row limit. The source fix and4 focused tests pass; device repair acceptance remains pending. Office close receipts and the remaining N01–N08 scenarios stay open. Cleanup measured about3.46GB; iOS Latest is preserved.
