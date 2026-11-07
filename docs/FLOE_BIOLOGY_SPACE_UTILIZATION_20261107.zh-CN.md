# 生物工作台空间利用率增量（2026-11-07）

实现检查点：`f00e150cd050b8515398d8c39673c4ff4285a9bb`。用户指出上一张横屏截图空间浪费严重，本次调整实际取景和布局，保持既有编辑、计算、AI 工具及任务契约。

- 三维“适合窗口”按显示坐标、透视视锥和原子半径计算，替代过于保守的包围球距离；必要时转动相机使结构更适合当前宽高比。源坐标和物理比例不变，保留边缘余量、旋转、缩放和适合窗口操作。
- 分析栏默认宽度从 380 点降到 320 点，可调范围为 280–360 点。常用参数改为标题和值同行，减少重复标题、外边距和分组间距；辅助阅读的大字体仍使用上下布局。
- 资料标题栏、三维工具栏及底部信息压缩排列，数量、图例和选择反馈共用自适应行；选择框、适合窗口、关闭和运行按钮保留 44 点区域。
- 短序列不再显示无用分页按钮；小型树、双节点网络和序列文本预览按数据量取高，不强行撑大白色画布。

## 实际截图与测量

| 项目 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 分析栏默认宽度 | 380 点 | 320 点 |
| 同一蛋白的着色显示像素 | 60,379 | 209,618（约 3.47 倍） |
| 横屏模型视区 | — | 789 × 487.5 点 |
| 视区占整屏宽 / 高 | — | 69.6% / 65.5% |
| 方法、位置、模型、链参数组高度 | — | 168.5 点 |
| 四个选择框高度 | — | 均为 44 点且可点击 |

屏幕为 1133 × 744 点；视区 `(12, 198.5, 789, 487.5)`，运行按钮 `(825, 668, 296, 44)`。像素比较仅统计原始图中画布区域的有色模型像素，代表屏幕显示面积，非生物表面积；算法、范围和原图哈希见 [测量记录](qualification/biology-space-20261107/measurements.json)。读取 EXIF 方向用于内存计算，没有旋转、裁剪或改写原始 PNG。

[修改前](qualification/biology-layout-20261107/landscape-inspector.png) · [修改后](qualification/biology-space-20261107/landscape-inspector.png) · [全部 12 张原始截图与来源](qualification/biology-space-20261107/screenshots.json)。小型 [系统树](qualification/biology-space-20261107/tree.png)、[网络](qualification/biology-space-20261107/network.png)、[序列](qualification/biology-space-20261107/sequence.png) 和 [密度表面](qualification/biology-space-20261107/density.png) 同批检查。原子图保留旋转后的交互状态；紧凑取景保证初始 / 适合窗口视角，用户旋转或放大后仍可再次适合窗口。

## 验证与交付边界

Xcode 27.2（27B52）、Swift 6.4.2、iPhoneSimulator 27.2 SDK；实际运行仅使用既有 canonical iPad mini（A17 Pro）iOS 27.0，未创建、抹除或使用实体设备。对象编译和 `build-for-testing` 通过；选择以下检查，不重复未改变的科学引擎矩阵：

| 检查 | 结果 |
| --- | --- |
| `swift test --filter BiologyScientificViewTests`，独立内部 SSD scratch，6 jobs | 7 passed / 0 failed：新增原子球边界、真实 ribbon / 密度在不同宽高比的取景，以及无效输入；既有四项几何回归保留 |
| `testFramedControlsUseTheirFullHitArea` | 59.264 秒通过；框内点选、真实选中值 11、四个 44 点参数和结构计算 |
| `testVisualWorkbenchPortraitAndLandscape` | 81.398 秒通过；横竖屏、全部专业视图、视区比例、参数组尺寸、无重叠和实际网络结果 |

UI 为 `ipad-space-05` 同一轮 2 passed / 0 failed / 0 skipped，通过原生窗口锁 → canonical 锁运行 `test-without-building`，禁用并行。原始首轮编译的 `pi` 类型歧义、`space-03` 检查器已打开却再次切换而关闭的用例失败均保留；修正明确类型和实际目标状态后确认，未删减尺寸、命中及真实计算断言。`space-04` 排队期间发生其他任务源码变化，冻结器拒绝绑定，不将其编译成功作为精确产物资格。

xcresult 另有两条 Internal QoS 等待警告，未做性能剖析；Xcode 运行后附加诊断仍出现历史 `simctl` 查找警告。测试返回 0，显式工具链关闭设备成功，未修改全局 Xcode。原图和 summary 串行导出读取；并发读取 xcresult 时的数据库临时文件冲突另有私有记录，未重复实际测试。

精确独立宿主包为 `Local/Artifacts/FloeBiologyKit/20261107/round2/FloeBiology-space-05-iPad-Simulator.zip`，SHA-256 `23b82e3ab7e8f5c91366f25a14992eaade3350821d45727da6fcc7bde370b2e1`。已校验 ZIP、arm64 IOSSIMULATOR 可执行文件和实际 debug dylib；同目录保留 82 文件完整源 ZIP、清单、源码/产物/测试绑定。源 ZIP SHA-256 为 `4417b14031f8f71dbf9aaae86ac570671bad8b85cdc3eceb36d66da8cf665792`。同 checkout 后续 App 适配的修改不归入这份冻结证据。

这次仍是独立组件宿主验收；完整 App、真实模型 / Linux 路径、iPhone、iOS 26 运行时和实体设备由其对应验收确认。本轮不更改 App 版本、315/325 或分发；交接见 [App 接入记录](FLOE_BIOLOGY_APP_HANDOFF_20261107.zh-CN.md)。

已删除本任务 `Xcode27.2/swift-tests` 和 `ipad-host` 缓存，合计已分配约 420.4 MiB；内部卷空闲实测增加约 423.7 MiB（含并发 APFS 活动）。删除被最终包取代的 `space-02` 中间 ZIP / sidecar，保留其日志与绑定、失败复现 `space-03` 和最终 `space-05` 原件。canonical 已关闭，未删应用或数据，未清理其他任务缓存。
