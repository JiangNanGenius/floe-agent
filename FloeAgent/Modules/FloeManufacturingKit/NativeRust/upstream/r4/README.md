# upstream/r4 — OpenMill@0432a8c 提取件（R4 CAM 域）

来源仓库：`charlatanshost/OpenMill@0432a8c540d1187dc6cb9383ce1b4f2dd97287f6`
（本地证据副本 `parameters-evidence/sources/openmill-0432a8c/`）。许可：MIT
（选择 MIT 选项，见 `../LICENSE-MIT`；原上游许可记录一并保留）。
本目录每个 `.rs` 文件头部均带 SPDX 与逐段改动映射；此处为总览。

## 提取与改动映射

| 文件 | 上游来源 | 提取内容 | Floe 改动（全部记录于文件头注释） |
| --- | --- | --- | --- |
| `tool_profile.rs` | `tool.rs` `ToolShape::cutter_radius_at`（约 121–194 行） | 刀形半径剖面 `cutter_radius_at`（仅 flatEndMill / ballNose / drill 三型）+ `drill_tip_height` | 删去其余六种刀型；函数改为自由函数（不依赖 Tool 结构）；f64 不变。**有意偏差（已记录）**：上游 Drill 臂是恒定半径、不建模钻尖；合同要求真实钻尖，此处为 `min(r, h·tan(半角))` 锥段。 |
| `drilling.rs` | `strategies/drilling.rs` 全文件 | 孔循环运动展开 `expand_hole`：`drill`/`counterBore`/`peck`/`chipBreak`/`bore` 五循环的 Rapid/Linear/Retract/dwell 展开与 `effective_peck`。 | 输出目标从 `ToolpathPoint` 改为 Floe `CamMove`（move 语义等价映射）；上游硬编码 `CLEARANCE_MM=10.0` 改为调用方传入的 `clearance`；dwell 从零进给 Linear 点改为显式 `Dwell` 移动；删除 `ToolpathStrategy` trait/模型依赖；保留逐循环注释与语义。 |
| `raster.rs` | `strategies/pocket_clearing.rs` 行切核心（约 155–228 行） | 圆形型腔 zigzag 行生成：层深 step-down、行间 step-over、往返方向交替、圆形足迹内缩裁剪（`circle_rows`）；通用矩形行生成 `rect_rows`。 | 坐标从世界 XYZ 改为 frame 局部 (u,v,w)；行间插距从硬编码 1.0 改为调用方弦长参数；上游「型腔小于刀具静默 continue」缺陷在此**不沿用**——由调用方转为明确失败；行首 plunge/行尾 retract 由调用方显式发出。 |
| `surface_normal.rs` | `strategies/surface_normal_5axis.rs` parallel 扫描 + `calculate_tool_pos_with_offset` | 竖直射线的网格命中+法向查询 `raycast_down`、球头/平底接触定位 `tool_pos_for_contact`。 | 去掉 lead/tilt 角（合同 Operation 无此字段）：刀轴=命中法向（朝 +axis 侧翻转）；坐标改 frame 局部；去除 `Tool`/`WorkpieceModel` 依赖，网格为 Parry3d `TriMesh`（pinned 0.17.6，与上游声明 0.17 同族）。 |
| `swarf.rs` | `strategies/swarf_5axis.rs` | `flank_offset_dir`（法向去 ruling 分量、内向翻转、垂直面拒绝）逐行移植；径向 ruling 配对扫描 `ruling_scan`。 | 扫描中心/半径由调用方按 frame 特征给定（上游用模型 bbox）；z_top/z_bottom 改为 frame 深度 w=0 / w=depth；保持上游星形凸（star-convex）适用范围声明，阴影区 ruling 缺失由调用方计数进 limits。 |

## 明确不提取的内容（缺陷或超范围，如实记录）

- `pocket_clearing.rs` 的 **raycast 钳位到 mesh 表面**逻辑：R4 圆形型腔为显式二维特征、
  不依赖 partMesh，钳位无对象；且其对 raycast miss 的处理（保持 floor）对 voxel 毛坯
  无意义。
- `contour_parallel.rs` 的 360° 圆形扫射水线：上游以模型 bbox 中心扫描、命中即偏置，
  对非圆截面会产生不完整/错误环路；R4 contour 直接对显式圆/矩形边界做精确解析偏置，
  不沿用该扫射。
- `adaptive_clearing.rs`（上游自述 starter/trochoidal 未实现）与 `multi_axis_roughing.rs`
  的 medial-axis/voronoi 粗加工：上游未完成，R4 不宣称。
- `tool.rs` 的 `holder_collision` 顶点法：R2 已由 `src/assembly.rs` 的 Parry3d 分段查询
  取代（更严格），不重复提取。
- 任何 `.unwrap_or(false)` 静默无碰撞 / raycast miss 静默跳过模式：一律改为明确
  计数（limits）或显式失败。

## Root 集成修正（覆盖初始交接中的差异描述）

- 孔循环的上游 +Z 运动在策略边界一次转换为本合同的正深度 w；不更改上游展开数学。
- 所有正 peck 深度均原样参与工作量检查；过小值在生成任何运动前明确拒绝，不当成缺省值。
- Swarf 边界射线向面内微移后按直线 ruling 外推回精确深度平面，避免盖面/侧面共享边数值退化；
  任何缺站都明确失败，绝不跨缺口连刀；完整一圈显式闭合。
- 各项改动的原稿、Root diff、原始失败与96项单测/13个C ABI运行案例见 r4/evidence，
  不是由历史 worker 的 source-ready 文档宣称通过。
