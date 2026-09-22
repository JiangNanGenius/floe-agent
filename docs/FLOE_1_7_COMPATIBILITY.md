# Floe 1.7 兼容性说明 / Compatibility

本页是当前资格边界，不是已发布能力清单。详细逐项制作与真机验收仍未完成；[实施状态](FLOE_1_7_IMPLEMENTATION_STATUS.md)记录进度。

逐条登记见 [15 个包与 33 个模型资格矩阵](FLOE_1_7_QUALIFICATION_MATRIX.md)，其中未验收项不作为可用能力。

## 运行时与软件包

| 类型 | 当前证据与限制 |
|---|---|
| Linux 客体运行时 | TinyEMU RV64 客体承载本地 Python/Node/Shell；首次使用的自动准备流程、客体网络与持久磁盘在 Build 219 的定向／云端检查中覆盖，完整真机行为仍由用户验收（见 [Linux 后端](FLOE_LINUX_GUEST_BACKEND.md)、[Build 219 说明](RELEASE_NOTES_1.7.0_BUILD_219.md)） |
| shell（原生兼容后端） | 原生模拟器 26 项命令及交互输入通过，含参数原样传递、导出变量、多段管道、取消和线程退出；显式设为**原生**的环境才使用该后端 |
| Node | 使用客体 apt 的 `nodejs`/`npm` 与环境前缀，Node 版本随客体镜像；进程内 NodeMobile 18.20.4 与相关宿主测试已退役，仅作历史证据 |
| npm / pnpm | 客体自带管理器执行环境安装；pnpm 仅在客体提供时可用，公共包兼容性不逐个承诺 |
| Python | 客体 Debian python3 加环境共享 venv（`/floe/env/python/venv`）；pip 使用环境配置的索引，riscv64 兼容包可装，缺少对应构建会明确失败 |
| 原生扩展 | 需匹配 Linux 客体 ABI 或由技能安装器审计的纯 Python universal wheel；普通 iOS wheel／原生扩展不再随 App 分发 |
| apt / dpkg | Linux 环境内为客体真实 Debian apt/dpkg；原生环境保留签名目录查询与经审核的纯数据 `dpkg-deb` 操作 |
| 通用解释器（PHP/Ruby/Lua/WASI 包） | 这些能力统一收敛到 Linux 客体：`exec.wasm`、`exec.compatEvaluator`、`wasm.packages` 在能力路由器中声明为客体后端，已安装的签名 WASI 包与其收据、许可证与来源记录保持不变（不删除用户安装，见 [语言能力路线](../capability-hub/LANGUAGES.md)） |
| 后台执行与状态 PiP | 显式用户任务默认使用系统持续处理任务（Live Activity）+ 30 秒完成窗口 + 检查点恢复；状态画中画是**可选**表面，由 `StatusPiPReleaseGate` 控制，关闭时画中画选择降级为普通后台任务，不会创建控制器（见 [架构总览](ARCHITECTURE_OVERVIEW.md)） |
| 资源指标（Linux 会话） | 只显示可测量值：模拟器线程 CPU、客体 `/proc` CPU、客体内存、网络累计；缺失值显示“—”，GPU 恒为不可用（TinyEMU 无 GPU 直通）；采样只在有消费者且前台时运行，不使用静默音频续命 |
| 维护脚本/特殊文件 | 未接通时拒绝，不能返回假成功 |
| 15 个软件包候选 | 逐版本制作/实测结论未完成，不能全部展示为已可用 |
| Office 文档（DOCX/XLSX/PPTX） | 原生宿主已编译链接并固定，但演示文稿的可见渲染、真机往返与写回仍未取得证据：框架中 `embeddedEditorPassed`、`pptxVisibleRenderPassed`、`deviceRoundtripPassed`、`originalFileWritebackPassed` 全部保持 false，发布门禁因此拒绝把 Office 宣称为已资格化能力。本轮 PPTX 修复（演示版式的受控编辑入口、必须出现真实文档图块才就绪、无渲染时有界失败并保留副本）已进入宿主源码与应用层；宿主已由 [office-native-host](https://github.com/JiangNanGenius/floe-agent/actions/workflows/office-native-host.yml) 运行 35668651442 重新编译链接并于 2026-09-22 重新固定（提交 `f0ca71a7`），四项设备能力回执仍为 false，真机演示/保存/重开与写回验收仍由用户完成。详见 [Build 156 反馈修复记录](FLOE_156_FEEDBACK_REPAIR.md)。 |

历史记录：[Node 说明（已退役）](FLOE_1_7_NODE_RUNTIME.md)、[Build 156 反馈验收记录](FLOE_156_FEEDBACK_REPAIR.md)。官方 Release 验签不能因信任密钥为空而跳过。独立 hold 状态、安装层及依赖查找均须归属当前环境。

## 媒体

已实现的有界转码路径应用 H.264/HEVC、尺寸、帧率、码率和支持的封装参数；音频转换应用采样率与声道参数。宿主测试验证了真实输出重读，包括视频尺寸/帧率/样本数及 48 kHz 双声道到 16 kHz 单声道转换。其他编码器、所有组合、长文件、旋转、音画同步和真机成本尚未全面验收。

未接通的增强处理器不会作为可用工具注册。插帧、超分等不能仅返回“待处理”文本作为成功。已接入播放器、单素材编辑、保存重开，以及 VideoEditorKit 的剪裁、旋转和手动字幕；中文定时字幕已通过真实导出像素检查。共享任务、聊天附件入口和完整真机验收仍未完成。

## 模型

AMT、E2FGVI 因非商业限制且未取得额外许可，GPEN 因未取得可核验分发许可，已从本轮官方分发候选中排除。具体来源见[资格矩阵](FLOE_1_7_QUALIFICATION_MATRIX.md)。

现有 [33 项模型源码清单](../skill-hub/models.json) 包含候选及待审核资产，不是可下载承诺。每项需记录许可证、权重来源、可分发性、转换方式、输入输出、设备耗时与内存，以及最终保留/替代/排除结论。不能把缺少权重的条目包装为可安装模型。

本轮必须覆盖以下 15 类，每类至少有一个可验证实现：插帧、超分、降噪、修复、人脸修复、分割、深度、上色、修补、场景检测、OCR、检测、转录、分轨、音频降噪。当前尚未完成这些类别的整体资格证明。

默认模型只能从设备、运行器和资源均通过验证的版本中选择。模型按需下载；安装成功与推理通过分别记录。候选 Skill 描述不能越过 App 的实际工具发现和能力报告。
