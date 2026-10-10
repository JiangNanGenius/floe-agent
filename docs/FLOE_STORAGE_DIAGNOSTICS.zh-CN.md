# 储存空间诊断与安全清理

状态：源码已实现、聚焦测试通过，**尚未进行真机验收**。本文描述当前行为，不声称设置中的数字与 iOS“储存空间”完全一致——见“诚实边界”。

## 背景

设置 → 数据管理过去把 Library + Documents + tmp 相加，并把稀疏 VM 磁盘的“表观大小”计入，导致 Floe 的数字与 iPad 设置不一致。**真机上的物理根因尚未被证明是单一因素**（旧代码本就在使用 allocated 大小键）。本次重写用透明、分类、按文件身份去重的计量和具备所有权意识的清理替代猜测。

## 计量引擎

`FloeAgent/Sources/FloeCore/StorageAccounting.swift`（`StorageCensus`）：

- **单次互斥遍历**：重叠/嵌套根按最深匹配归属，每棵物理树只遍历一次。
- **精确身份去重**：device + inode 对硬链接和根重叠去重；被去重的字节单独报告（`sharedSize`），绝不重复累加。
- **逻辑 vs 已分配**：`logicalBytes` 是表观长度（稀疏 VM 磁盘即*配置的客体容量*）；`allocatedBytes` 使用 `totalFileAllocatedSize`（主机实际分配、感知稀疏）。两者分开保存并分别展示。
- **隐藏文件**默认计入，不会静默漏掉暂存/`.trash`/`.downloads` 等目录。
- **竞态与错误**：扫描中消失的文件计入 `changedOrVanishedCount`，无法读取的条目计入 `errorCount`；不删数据、不静默忽略。
- **进度与取消**：轮询 `isCancelled`，抛出 `StorageCensusError.cancelled`；界面提供“停止扫描”。
- **克隆不确定性显式化**：APFS 写时复制克隆在不同 inode 间共享块，无法从 `stat` 拆分。克隆来源的根（内容寻址运行时镜像库）**仍全额计入**——克隆可能持有独有块——报告标记 `isSharedAllocationEstimate`，绝不因“可能共享”而扣减。

测试观察到的 APFS 行为：约 16 MiB 以内的文件按全额分配报告（小文件预分配）；真实 VM 磁盘（16/32 GiB）能正确反映稀疏分配。详见 `Tests/FloeCoreTests/StorageAccountingTests.swift` 注释。

## App 接线

`FloeAgent/FloeApp/Settings/StorageDiagnosticService.swift` 构建真实根列表，覆盖旧检查器从未扫描的根：

- `FloeAgent/Environments`（容器层、每环境稀疏 Linux 磁盘 `LinuxGuest/disks/<id>/disk.img`）
- 同级的 `Floe/Runtime/v2`（blob/展开镜像/VM 磁盘，克隆来源）
- `Materials`、`Canvases`、`MediaProjects`、`CanvasCAD`、`LocalModels`、`PrivateTasks`、`Fonts`、`Attachments`、`GeneratedImages`、`BrowserArtifacts`、`Checkpoints`
- `Caches`/`tmp` 作为可回收估算单独展示，不列为用户数据分类

分类展示项目数与主机已分配字节；VM 磁盘分类额外展示配置容量。只要存在克隆来源根，总量即标注为估算；出现错误/竞态时显示“部分扫描”警告。

## 安全清理

`FloeAgent/Sources/FloeCore/StorageCleanup.swift`（引擎）+ `FloeApp/Settings/StorageDiagnosticService.swift`（注册计划）取代早期“整目录清空 Caches/ 与短时 tmp”的方案（该方案已不存在于代码）：

- **仅显式注册候选项**：每个候选项带所有者、标题、用途、保留原因与时间阈值。当前计划只有一个候选：任务持有的专用 scratch 根 `tmp/FloeAgent/scratch`（组件 purpose 前缀过滤 + 24 小时静默期 + 租约保护）。整个 tmp 根与 Caches 目录从来不是候选。
- **保留注册项**：Floe 的 `Caches/FloeAgent` 存放用户数据与恢复状态——提示词库（用户创作）、诊断日志与 PDF 操作日志——全部注册为*保留*并附原因，永远不会成为候选项。
- **失败关闭**：每次删除都要求所有者探针明确证明空闲（无运行环境、无模型下载、无未完成媒体任务），并在候选级与逐项删除前重新探测。未知、忙碌或探测出错时不删除任何内容。
- **跳过计数**：最近项、受保护名称、符号链接及含活跃写入子项的目录均计入跳过；清扫安全守卫会拒绝任何误注册的缓存父目录。
- **诚实结果**：报告删除/所有者忙碌跳过/受保护跳过/最近跳过/失败数量、清理根上的**已分配字节观察变化**（明确说明在克隆/稀疏卷上并非精确物理释放量），以及可测量时的卷可用空间变化。绝不把文件大小之和当作释放的卷字节。
- **可清理估算**：界面“可安全清理”使用与执行相同的所有者/时间/保留规则计算，不是整目录大小。
- **取消**在项目之间生效。

## 测试

FloeCore 聚焦测试覆盖：普通文件、稀疏磁盘（逻辑 vs 已分配）、硬链接只计一次、嵌套根、parent/未归属文件、不跟随符号链接、隐藏文件、消失文件、取消；报告算术（每个桶只计一次、缓存计入总量但不列为分类、稀疏容量展示）；清理安全（所有者忙碌时失败关闭、仅删除符合条件项、跳过计数、逐项所有者复检、缓存父目录拒绝、保留注册）。FloeApp 编译包含在完整 App 构建中。

## 诚实边界

- 已分配总量可能包含与克隆兄弟共享的块，是**上限估算**，不是精确可释放值。
- iOS“储存空间”的统计方法未公开；Floe 不声称两者必须一致。
- 界面在英文与中文中都明确标注共享分配说明。
- 清理绝不把候选项大小之和等同于实际释放的卷字节。

## 当前实现（2026-10-10 修正）

- 诊断引擎始终使用 allocated（稀疏感知）键；此前的背景描述若称“旧扫描器把表观大小计入”不准确，已按代码事实修正。真机“系统 20+GB / 应用显示 100+GB”差异的根因未最终证实，文档不作未证明断言。
- logicalBytes 是文件表观长度（qcow2/元数据等会使其偏离真实来宾容量），绝不等同于配置来宾容量；客户机已用空间只能在客户机运行时测量。
- 安全清理的唯一可删候选是任务持有的专用 scratch 根（`tmp/FloeAgent/scratch`）：按组件 purpose 前缀过滤、24 小时静默期、每路径引用计数租约、删除认领与租约原子互斥；交付给分享/预览的文件持有租约令牌，消费者关闭时释放。整个 tmp 根与 Caches 目录从来不是候选。
