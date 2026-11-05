# Floe Agent 1.7.75（316）交付记录

日期：2026-11-06。不可变来源：`249c718875acc31ceadbbfe50ca5fd486dead978`，标签 `v1.7.75`。本记录补充冻结后的结果，不改变标签、源码或产物。

## 简体中文

- 修复背景音恢复播放时未应用当前音量的问题：后台播放器暂停期间改变音量，恢复时可能沿用旧值，而界面已显示新值。现在先设置音量再恢复；零音量仍保留用户开启的播放功能。
- 原生 CAD 视图观察接受等轴测、正面、顶面等标准视图名称，同时保留原有自定义角度格式；无效名称返回可操作的说明。没有把模型服务超时或未确认收到图片的问题算作已解决。
- ARM64 解释器减少已绑定 MMU 的重复调用，并在实时栈指针对齐时复用已有预解码内存指令。未对齐情况保留原解码器与异常顺序。停止、IRQ、TLBI、同步、预算和执行批次上限不变；测量无收益的核心填充方案未合入。

### 编译与验证

- 最终来源使用 Xcode 27.1（27A9275）、Swift 6 实际编译 App／测试宿主，并完成 arm64、iOS SDK 27.1 Release 归档。
- 固定 iPad 模拟器通过 52 项音频及 CAD 观察测试，零失败、零跳过；动态参数测试实际运行两个音量场景。冻结 315 测试宿主上的两个恢复场景均记录旧值 0.6，修改后正确应用 0 和 0.25。另行启动最终 App 并检查启动截图，保留原有草稿。
- ARM64 与原解码器的 1,248 项栈、对齐、FP、MMU 和故障比较通过；10 项正常组件检查通过。全部 30 个翻译单元重建 ThreadSanitizer 后，12 项组件检查通过，没有增加抑制规则或放宽断言。
- 一组实际宿主 Linux 配对的 PBKDF2／zlib 吞吐分别提高 4.14%／1.74%。另一组固定工作量 Python 配对的单进程／双进程吞吐提高 13.9%／9.0%。这是同宿主有限样本，不代表所有任务，也不是新一轮物理 iPad 或四核加速验收；四核扩展仍待优化。详见[性能记录](../../ARM64_PARALLEL_PERFORMANCE_20261106.md)。
- 原始失败保留：旧控制钩子在未修改基线上同样失败、首次测试选择器实际执行零项、新 Python 测试夹具缺少共享内存挂载、截图启动及保存位置问题，均未被算成通过。修正夹具后只重验相关部分。
- 首次归档已编译成功，但产物校验拒绝了沿用的 315 配置描述证明。按最终来源重新校验全部五项描述证明后，复用同一份已保存 App 和符号完成校验、打包，没有重新编译、修改产物或放宽检查。

### 分发与审核

- [签名、上传及内部读回](https://github.com/JiangNanGenius/floe-agent/actions/runs/42046811547)成功。Apple 显示 `VALID`、未过期，现有 Floe QA 为 `IN_BETA_TESTING`：316 已可供内部测试安装。
- 公开 TestFlight 已提交现有 `publictest1`。[独立只读核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/42052744268)确认群组已关联、仅有一次提交、双语测试说明及审核备注匹配，状态 `WAITING_FOR_BETA_REVIEW`／`pending_review`。等待审核不等于 316 已公开可安装。
- API 的审核备注及外部群组写操作各返回 403，原始日志保留；使用现有 Safari 登录完成备注保存、关联和一次提交，再通过独立 GET 核验，没有重复上传或重复送审。自动通知测试员保持关闭。
- 315 正式 App Store 仍为原来的等待审核项目，本轮未撤回、替换或重排；原有通过后自动发布设置未修改。316 按本轮范围只交付内部及外部 TestFlight，没有发布新的 App GitHub 安装包或 Feather 条目。
- 本轮未使用物理 iPhone，没有新的物理 iPad 听音验收；服务回归通过不能替代实际扬声器效果。

### 收尾

保留最终来源、原始 App 恢复 ZIP、含全部 14 份符号的交付 ZIP、摘要、验证记录和原始失败。逐文件核对 5,263 份原始产物的恢复字节，并保存归档元数据后，删除本轮重复归档、展开的 App／符号和传输暂存目录：合计分配 6,567,018,496 字节，外置卷实测可用空间增加 2,131,976,192 字节；克隆共享块和并发写入使两者不同。

已另行移除本轮 Release DerivedData（分配 4,199,878,656 字节）及用完的原生测试缓存。共用依赖、增量 App 测试缓存及其他线程的冻结 315 宿主保留用于后续工作。已消费的私有传输草稿及临时引用读回不存在，不可变 `v1.7.75` 标签保持不变。固定模拟器已关闭，未删除设备、用户数据或证据；Safari 临时标签页已关闭，窗口恢复原尺寸。

仓库保留唯一 main 工作副本及本地／远端 main 分支。后续 main 上的技能工作流锚点与本次交付文档提交独立于冻结的 App 来源；其他预研不作为本版门槛。

## English

Build 316 reapplies the current ambient gain before resuming a paused player,
accepts named CAD observation views while retaining custom angles, and reduces
MMU binding and aligned-stack interpreter overhead without changing lifecycle,
synchronization or exception checks. Final-source Swift 6 App/test compilation,
the device archive, 52 canonical-iPad simulator tests, 1,248 native decoder
comparisons and normal/ThreadSanitizer component checks passed. Original failures
remain available. An outdated profile-proof source was corrected by revalidating
the five profiles against the frozen source; the original saved archive was
reused without recompiling or weakening validation.

Limited host Linux pairs showed 4.14%/1.74% throughput gains for PBKDF2/zlib and
13.9%/9.0% for fixed-work Python at one/two processes. These are not new physical
iPad results and do not establish solved four-core scaling. No new physical
listening test or provider screenshot-receipt acceptance is claimed.

Apple reports VALID, unexpired and IN_BETA_TESTING for Floe QA. One publictest1
submission is waiting for Beta review; public installability is not claimed.
The existing formal Build 315 submission and automatic-release choice remain
unchanged. No new App GitHub/Feather distribution was made. Exact recovery
artifacts and all 14 symbols were retained before removing consumed duplicates;
the private transfer draft was removed, and the canonical simulator was shut
down without erasing data. The repository remains on main.
