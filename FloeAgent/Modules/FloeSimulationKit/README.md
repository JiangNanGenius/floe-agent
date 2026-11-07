# FloeSimulationKit

原生 3D 仿真、动画与 CAE 工作台的预研发模块，最低 iOS 26 / macOS 15，使用 Swift 6。范围和阶段见[预研发计划](../../../docs/FLOE_3D_PHYSICS_CAE_ANIMATION_PREDEVELOPMENT_PLAN.zh-CN.md)。

## 当前代码

| 模块 | 实现 |
| --- | --- |
| Core | SI 单位接口、几何与研究修订、网格、区域材料、时间/频率、预算、结果场及原生后端合同 |
| Geometry | Netgen 6.2.2507 原生网格；iOS 复用 OCCT 7.8.1 读取 B-rep，支持带标签封闭三角曲面、空腔、多区域、局部尺寸与精确体单元面引用；macOS arm64 为曲面路径 |
| Physics | Rapier 0.36.1 原生 C ABI；刚体、基本体/凸包/静态三角碰撞、关节和驱动、运动学关键帧、规则绳索/布料/体柔体；粒子发射、种子、寿命、阻力及均匀/吸引/涡旋力场 |
| Animation | 关键帧层、FK、双骨骼 IK、物理绑定、相机同播、Morph、缓存插值、可取消的运动烘焙与运动数据导出 |
| Engineering | 复用现有 tet4 静力与稳态热，显式转换 mm/N/MPa/°C 与 SI；梁壳/铺层、模态/屈曲、非线性/接触、瞬态热/热应力的配置和高级驱动入口 |
| Fields | MFEM 4.8 CPU 串行静电与复数压力声学；其余流体/电磁/射频配置与驱动入口；精确界面映射、载荷伴随转移及分区迭代合同 |
| Runtime | 分析与网格服务持有任务、停止请求与实际停止分离、修订围栏、共享网格/复材失效、工作区 CAS、分块结果及校验和、原子保存、索引/分页/CSV、带任务授权的工具命令 |
| UI | iPad 面板和紧凑布局、研究/动画编辑、材料/铺层、载荷/边界/端口、时间轴、探针、状态、停止和导出；由宿主注入已有视口 |
| Samples | 明确标识的悬臂、导热、刚体/布料、粒子资格样例 |

当前实际可运行的计算后端是 `floe.tet4`、`floe.rapier`、`floe.particles`、`floe.fields.mfem`，以及独立的 Netgen 网格服务。MFEM 当前只声明静电和压力声学，使用 tet4 体网格、1–3 阶 H1 有限元。高级结构、CFD、磁场、射频和耦合驱动仍返回明确不可用状态，执行能力及参数模板发现只返回实际已链接的种类。

待完成的计算工作包括 FEBio/Chrono、谱分析与热扩展、SU2、低频磁场、Palace 串行射频、ozz 接入及完整多场求解。实际 App 的 CAD 几何捕获、Metal 结果显示、现有 Studio 工具注册、视频和动画资产导出仍待接入；当前独立工作台和运动 JSON 导出不代表这些 App 路径已完成。

静电支持区域介电常数、电势/接地/绝缘边界、电场/电位移/能量和能量等效电容；悬空域及冲突电势会被拒绝。压力声学支持复数声压、法向速度、被动复阻抗和一阶辐射边界、区域介质与损耗、频率扫描、速度及声压级。相量约定为 `exp(+iωt)`，幅值为峰值，声压级使用 RMS。没有通过修改物理算子对角线来掩盖不收敛。

## 构建

Rapier 静态库由固定 Cargo.lock 构建。首次使用 SwiftPM 前先生成 XCFramework；该可再生产物不入 Git。脚本保存三个分片、每个输入和产物的 SHA-256 及依赖许可证。

以下命令在本包目录执行。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
python3 -B Native/Physics/build_apple.py \
  --build-root "$HOME/Library/Caches/CodexBuild/FloeSimulation/0dd039b5b74b/xcode-27B52/rapier"
```

已有本任务产物时可用 `--replace` 进行构建成功后的替换。共享主机的编译由协调端使用同一原生构建锁串行安排；不要和 App 编译叠加。

首次使用还需要生成两个 C++ 静态框架。以下命令同样在本包目录执行，并由协调端串行安排。OCCT 使用现有 CAD 包的固定分片，不复制到 Netgen 库内。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Native/Fields/MFEM/build_native.py --platform all
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Native/Fields/MFEM/build_native.py --package
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Native/Geometry/build_native.py --platform all
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -B Native/Geometry/build_native.py --package
python3 -B Native/verify_apple.py --check
```

已有匹配产物时只运行只读 `--check`。C++ 打包器拒绝覆盖已有框架；修改原生输入时先保存旧产物和证据，再生成替代品。两个构建器固定上游压缩包摘要，并记录桥和头文件摘要；详细本地移植边界见 [Native/PORTING.md](Native/PORTING.md)。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --scratch-path "$HOME/Library/Caches/CodexBuild/FloeSimulation/0dd039b5b74b/xcode-27B52/package" --jobs 6 --filter '<changed behavior>'
```

检查限定在本模块代码和小型真实调用，包括碰撞/布料、粒子时序、SI 结构结果、相机与物理混合、缓存/烘焙、结果回读、修订失效、取消队列及 UI/工具共享状态。数值全面资格、完整 App 和物理设备验收分别记录。

## 宿主接合

1. 用当前 CAD 修订、内容 SHA-256 和稳定对象/面身份建立 `SimulationSourceRef`；长度在边界转换为米。
2. App 持有一个 `SimulationWorkbenchSessions`，通过其 `open` 取得同一项目目录的共享模型，显式传入保存目录与 `geometryProvider`。该回调捕获当前 CAD 的不可变几何并检查源修订，模型文字和工具参数不能替代它。B-rep 通过 `sourceLengthToMeters` 转为米；`SimulationGeometrySnapshot.surface` 已经是 SI，不再缩放。
3. 向 `SimulationWorkbenchView` 注入现有 CAD 视口。计算和播放结果不回写权威几何或装配姿态。
4. UI 和 AI 共用模型及其服务。使用 `SimulationWorkbenchFactory.tools` 接上现有任务授权回调，并把 `definitions`/`invoke` 接到现有 Studio 注册和调用链；该回调没有默认放行实现。
5. AI 先读取 `simulation.templates`、`simulation.read` 和 `simulation.mesh.info`。模板来自 UI 同一套默认配置，带完整实体示例和 SI 参数名；写入/运行参数必须携带上次读取的 `expectedGeneration`，不能因宿主重新建立上下文而覆盖较新的 UI 修改。研究更新还需要其 `expectedRevision`。
6. 宿主几何变化时用递增来源修订调用 `model.refreshSource`；重开时也会校验当前来源，清除旧网格绑定并保留历史结果。关闭 CAD 项目时调用 `sessions.close`，等待原生工作实际结束；关闭面板只停止观察。关闭后的旧模型和工具不能继续写入。
7. CAD 标签中的 `nativeIndex` 仅指同一 B-rep 内的一基拓扑序号；持久身份来自宿主 `sourceEntityID`。没有宿主标签时只生成表示摘要限定的面名，不将其当作跨修订的稳定面身份。

独立 iPad 宿主位于 [Qualification/Simulation](../../Qualification/Simulation/README.md)。其线框用于组件检查；实际 App 继续使用原有 Metal 渲染器。
