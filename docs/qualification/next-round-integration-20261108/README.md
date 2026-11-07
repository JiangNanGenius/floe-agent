# Next-round App integration checkpoint / 下一轮 App 接入检查点

2026-11-08. Scope: [N01–N17](../../FLOE_NEXT_ROUND_ENGINES_AND_USABILITY_PLAN.zh-CN.md), preserving the earlier C01–C67 ledger. USB serial is explicitly deferred until Apple approval; its driver and connection entry are absent from this candidate.

## Source and build / 来源与构建

- Base: `f045a79b434e028474fab95fce8d48cae6a8bacb` plus the recorded integration changes. Build-input manifest SHA-256: `56bb60cef2400dea3d717a0ced7c366b548e5d9870f055d301b24f6842a31711`.
- Xcode 27.2 (`27B52`), explicit `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; `FloeIntegrationAcceptance`, `build-for-testing`, generic arm64 iOS Simulator, six compiler jobs. Main App, hosted tests and UI runner completed object compilation and linking. Production inputs have not changed since that successful build; subsequent changes only correct UI test fixture names and row lookup.
- The preserved App25 Simulator archive is `1,145,367,744` bytes; SHA-256 `dc399b8da1acebe909e096c83b28a9c8558449ce43dfc22193d45880e6e176c9`; full ZIP CRC passed. The actual installed and manually checked main executable matches SHA-256 `a15de0647929b1c8036f0f7e22fd7679fd7bca0d680c405a4942d9246b48453b`.
- This is a local Debug Simulator candidate carrying unchanged version/build labels, **not** a replacement for frozen 325, a device IPA or a TestFlight delivery. No version, tag, upload, public beta, App Store submission, website or update feed was changed.

源码基于上述主线与本轮集成改动，完整 App、宿主测试和 UI 启动器均已实际编译、链接。构建后生产代码未变；最后仅调整了 UI 测试命名与列表定位。已保存精确产物、构建输入、原始结果和恢复材料；模拟器安装态主程序的哈希也已核对。未改动冻结的 315／325、版本号或任何分发渠道。

## Focused evidence / 针对性证据

There is passing evidence for **84 distinct cases across implementation batches**, including real registered-tool calls and native App services. This is not a claim that every recorded run passed or that the whole application was revalidated. Original failures and an interrupted broad meeting UI case remain in the evidence. The two final automated Biology/Files and Chemistry UI cases failed at fixture lookup/creation; manual review of the same preserved App subsequently verified the affected flows. The latest locator-only test edits were parsed, but the UI runner was not rebuilt or reported green.

已通过证据覆盖 84 个不同用例，按未变更边界复用各批结果，不将原失败改写成成功。最后两项自动化 UI 检查没有通过；随后直接操作同一 App 完成对应界面复核。自动化脚本的最终定位修改仅通过语法检查，尚无重新编译运行成功的结论。会议旧的完整草稿切换 UI 用例因连续长等待主动停止；本轮仅结算实际完成的原生助手、键盘布局检查。

| Scope / 范围 | Actual evidence / 实际证据 |
| --- | --- |
| N01 physics, animation, FEA / 物理、动画、有限元 | Four App integration cases have passing evidence, including actual CAD geometry, result fields, rig/camera mesh and sequential physics-animation exports with generation receipts. Native-component qualification remains separately identified. / 四项 App 集成用例均有通过证据，含当前 CAD 几何、结果场、骨骼／相机及连续导出。 |
| N02 biology / 生物 | Eleven App host/tool contracts passed; the actual editor created and reopened a sequence project and displayed original bases plus analysis controls. / 11 项宿主与工具合同通过；实际创建、保存、重开及数据／分析面板已观察。 |
| N03, N07, N09 UI and Space / 界面与空间 | Horizontal quick entries, grouped workbenches and Files More → Import were observed in the actual App. / 实际首页横滑入口、工作台分组及文件“更多→导入”已检查。 |
| N04–N05 history / 历史与复用 | Six history/serial contracts passed, including durable reuse and preventing implicit sends. / 6 项历史与串口合同通过，覆盖持久复用及不隐式发送。 |
| N06 meeting transcription / 会议转写 | Four native recovery cases passed after correcting AAC encoder settings; actual notebook/assistant/keyboard layout was reviewed. / 修正 AAC 编码配置后，4 项恢复用例通过；实际笔记、助手和键盘布局已检查。 |
| N08 file selection / 文件多选 | Four selection/trash/restore contracts passed. Manual long press, selection controls and batch-trash confirmation removed only the exact newly created QA fixture. / 4 项合同通过；人工长按、多选及批量删除只操作本轮精确测试项目。 |
| N10–N11 drawing / 绘图 | Eleven CAD/media/diagram input cases passed. Chemistry eraser mode was selected; its real touch toggle read back `0 → 1 → 0`, restoring the original preference. / 11 项输入合同通过；化学橡皮擦模式及实际触屏开关往返切换已观察。 |
| N12 previews / 预览 | Twelve App tests used real saved content, revision invalidation and cancellation across files and the five biology domains. / 12 项真实内容、修订失效与取消测试通过，涵盖文件及五类生物内容。 |
| N13 model tools / 模型工具链 | The twelve confirmed source-gap groups were implemented and compiled; affected registered CAD, biology, audio, music import, selection, result, library, research, network and discovery contracts passed. The expanded static inventory is not a count of live model calls. / 12 组已确认源码缺口已实现编译；受影响注册工具合同通过，静态目录不冒充真实模型调用数量。 |
| N14–N15 continuity and distribution / 问题继承与分发 | Earlier identities and failure evidence retained; public TestFlight remains a later evaluation. / 保留旧编号及失败记录，公测仍待后续评估。 |
| N16 serial / 串口 | Ordinary serial UX continues; USB driver, entitlement embedding and USB connection entry are excluded pending Apple approval. Source research and application receipts remain preserved. / 普通串口改进保留，USB 驱动、嵌入权限及入口暂不随包交付。 |
| N17 2D CAD / 二维 CAD | Native planar navigation and drawing-input contracts passed; actual UI showed a head-on drawing grid and no 3D orientation cube. / 平面导航与输入合同通过；实际界面保持正对平面，无三维方向立方体。 |

## Limits and cleanup / 边界与清理

M4 physical-device live speech, physical Pencil/mouse input, real AP/BSSID roaming, USB hardware, configured external scientific backends and live provider/model calls were not newly accepted here. No exhaustive screen, numerical-accuracy or stability matrix was restarted. Separate scientific-analysis qualification reports 18 numerical tests; those are not included in the 84 App cases.

本轮未新增 M4 真机语音、实体 Pencil／鼠标、真实 AP 漫游、USB 硬件、外部科学后端或供应商账号调用的验收。未恢复全页面、数值精度或稳定性矩阵。独立数据分析资格包的 18 项数值测试单独记账，不重复计入上述 84 项。

After preserving exact packages and original evidence, final cleanup removed the finished integration DerivedData, closed Simulator symbol cache, main UI runner and owner-confirmed completed simulation QA host. The final measured internal-volume free-space increase was `10,213,646,336` bytes (about 9.5 GiB), separate from earlier cleanup. Current Floe App/data, shared dependency caches, active LaTeX work and Biology QA apps with unconfirmed future use were retained. The canonical iPad was shut down, and its locks released.

保存精确包与原始证据后，收尾清理实测释放约 9.5 GiB；仅处理已结束的构建目录、关闭的符号缓存、自有 UI 启动器及原负责人确认闲置的仿真 QA 宿主。当前 Floe App 与数据、共享依赖、活动 LaTeX 和用途未确认的生物 QA 包均保留。复用 iPad 模拟器已关闭并释放锁。
