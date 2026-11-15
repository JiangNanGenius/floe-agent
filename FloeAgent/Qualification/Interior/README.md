# 室内组件原生验证

这是一套独立的 iOS 组件宿主。它通过现有 FloeCADKit 公开接口验证柜体领域数据与真实几何／出图接口的衔接，不接入完整 App，不覆盖用户工程，也不代表柜体生产验收。

2026-11-15：生产 CAD 源码已合入 Source16 二维楼层链路、宿主保存／撤销归属和导入实体变换保留修复；本目录的 `EditorHost/EditorUITests.swift` 同步为 5 项（原 4 项＋二维楼层工具栏），并新增 `BuildingProjectNativeImportTests` 两项工程导入测试。`EditorHost/project.yml` 的 `InteriorEditorChecks` 会从 `Modules/FloeInteriorKit/Tests/FloeBuildingEditorTests` 自动包含新测试。以上都没有编译或运行，不能计作通过。

## 检查内容

`NativeCabinetChecks.swift` 包含三项实际运行检查：

1. 19 块板件分别生成解析 BRep 实体，核对每块板件的体积及世界坐标包围盒；保存、关闭、重新打开后核对实体数量和内容身份；导出 STEP 后独立导入，匹配所有实体几何，并核对副本实际移动 10 mm 后原件不动。
2. 七块板件的柜身生成内部正立面、剖面及单件俯视轮廓，实际请求 SVG／DXF／PDF 文件，再保存三个图纸页。此处没有自动尺寸标注、图签或生产注记。
3. 19 块板件整体出图请求保留全部来源，验证现有核心返回 `too_many_bodies`，拒绝后不丢模型、不生成不完整图页。此项通过表示缺口被正确识别，不表示复杂整柜出图已完成。

`NativeCabinetAdapter.swift` 是研究适配器，创建全新草稿并保存柜体来源与板件到实体的对应。它没有实现修改已有项目的原子提交、整体撤销或跨数据库／CAD 文件事务。

首次三项接口检查通过后，PDF 复查发现默认视图方向不符合建筑语义；原始 `native-run02` 保留。当前源码改用共享 `InteriorDrawingFrame`，检查宽高不等柜身的实际投影范围与纸面位置，新增几何回执。`frame-fix03` 保留检查器图层解释错误和导入 STEP 体移动失败；`frame-fix04-private` 的三项已通过，三张新样图也逐页复查。后者使用私有 CAD 来源保存补丁，主线该文件未改，不能用该产物冒充原主线或 App 已修复。

该单文件修复（变换前保留导入体来源，作为同一次可撤销编辑）已于 2026-11-15 合入生产 `CADCommandExecutor.swift`，与既有 pattern／mirror 路径一致；它的原生三测通过证据来自私有证明副本 `Local/Artifacts/interior-component-research-20261112/private-cad-transform-proof/`（`frame-fix04-private`），不是对当前主线重新编译的结果。本目录的 `project.yml` 仍引用主线 CAD；新增 STEP 移动断言在合入源上预期可过，但本轮没有重跑，也没有放宽断言。

## 构建和运行

```sh
xcodegen generate --spec FloeAgent/Qualification/Interior/project.yml

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing \
  -project FloeAgent/Qualification/Interior/FloeInteriorQualification.xcodeproj \
  -scheme InteriorNativeChecks -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$HOME/Library/Caches/CodexBuild/FloeInteriorKit/ios-ai-agent/Xcode27.2/native" \
  -jobs 6 -parallel-testing-enabled NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 \
  FloeAgent/scripts/select_test_simulator.py --canonical --with-lock \
  python3 FloeAgent/Qualification/Interior/run_native_probe.py \
  --derived-data "$HOME/Library/Caches/CodexBuild/FloeInteriorKit/ios-ai-agent/Xcode27.2/native" \
  --output Local/Artifacts/interior-component-research-20261112/a-new-native-run
```

运行器依赖仓库既有的单设备配置和锁，不创建／克隆／重置模拟器；输出目录必须不存在。导出测试结果、附件和本任务的原生草稿。如果本任务启动了设备，结束时关闭该运行实例，保留设备和应用数据。组件工程由本目录的 `project.yml` 生成，未修改主 App 的项目配置。

## 成熟算法验证

`UpstreamWallProfilesProbe.mjs` 对固定版本 OpenPlan3D 的原始 `wallProfiles.ts` 和 `models/types.ts` 运行 10 个领域场景，并核对 Git blob 与本地 SHA256。仅替换模块导入路径以适应 Node 加载；未改写算法。原始 MIT 许可与源码保留在本轮本地证据目录，尚未作为 App 依赖分发。

```sh
node FloeAgent/Qualification/Interior/UpstreamWallProfilesProbe.mjs \
  Local/Artifacts/interior-component-research-20261112/upstream
```

固定来源为 [OpenPlan3D b0727b54](https://github.com/laanlabs/openPlan3D/blob/b0727b54da5f0f642722dcc88cc52d7236fadc9e/src/lib/utils/wallProfiles.ts)。覆盖直墙洞口面积、洞口并集、墙端裁切、斜顶洞口、整面洞口、无效输入、弧墙分段／贯通洞口、房间顶高及短踢脚线。输入为厘米，弧墙为 16 段折线近似；原生 mm 适配和精确弧线转换仍须独立验证。未运行完整 OpenPlan3D 编辑器，也未验证房间识别、RoomPlan 导入或原生 Swift 移植。

## 证据范围

本轮构建／测试日志、生成的数据、原生工程、导出图页与上游算法运行回执位于 `Local/Artifacts/interior-component-research-20261112/`。当前领域测试为 13 项；原生实际运行、私有补丁范围和 PDF 观察结果见[本轮记录](../../../docs/qualification/FLOE_INTERIOR_COMPONENT_20261112.zh-CN.md)。

DWG、IFC、家具原生网格导入、AI 生成家具、现场量尺精度、真实五金制造规则均不在此次原生执行范围；原有完整 QA 需求继续有效。

STEP 本轮补充了上述精确几何往返和副本移动检查；完整装配名称／层级和建筑语义尚未保留。家具素材另由 `inspect_furniture_library.py`、`stage_furniture_catalog.py` 做文件与数据库暂存检查，未原生导入；不要将它们与本宿主的 3 项测试合并成全部功能通过。
