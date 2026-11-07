# 音乐编辑工具与建筑入口接入检查点 / Music tools and Building entry checkpoint

日期 / Date: 2026-11-08

## 范围与结果

修复 `studio.edit` 音乐片段契约，并在实际 App 的已注册工具、原生存储和离线渲染路径验证 30 秒作品。补齐音乐工作台的音色与 MIDI 操作，移除重复助手入口；修复空间 CAD 中建筑专业二级页面的导航与文件使用期。当前为本地 Debug 候选，没有新建版本、上传 TestFlight 或替换已冻结的 325。

用户报告中的原始失败 JSON 未提供，因此不能认定当时具体是哪一个字段出错。已确认旧契约主要依赖 Swift 枚举的完整嵌套编码，片段新增／更新缺少完整示例，解析错误又没有报告字段。此次使用独立合成测试项目；没有修改或渲染用户原作品。

### 已实现

- 提供明确的 `midi.clip.insert`、`midi.clip.update` 格式，使用真实轨道／片段 ID、整数 ticks，以及显式 `notesMode: append|replace`。追加保留已有音符和未声明字段；新增由原生服务生成片段 ID。保留旧精确 Codable 格式兼容，禁止在同一批混用格式。
- 未知字段、目标不存在、非法音符、数值越界等在提交前报告具体路径、期望格式和恢复方式。保留修订、作用域、批量大小与失败保护；无变化不写入新修订。
- `studio.read` 返回实际能力目录、完整片段示例及音色／模板。明确 `masterStrip` 与辅助总线的区别，不把虚拟 master 路由 ID 当作辅助总线。
- `studio.run` 的 WAV／MP3 渲染支持 `inputJSON: {"tailFrames":0}`，可生成与内容严格等长的文件；省略时保留原有 48,000 帧效果尾音。渲染尊重保存的静音、增益与路由，保存本身不等同于生成音频。
- 41 个实际原生合成音色，分类、搜索、试听、应用和撤销共用真实会话。实时与离线采用同一音色定义；包含电子鼓组，没有引入外部采样包。
- 量化、移调、力度及鼓／和弦／琶音／贝斯模板进入 UI 与模型编辑链。模板添加新片段，保留原作品；音乐编辑页沿用顶部作品助手。
- 建筑功能沿用现有 CAD 原件与导航，在空间 CAD 可进入 IFC、梁结构校核、机电碰撞检查、信息要求检查并返回；导航持有既有文件租约，关闭后释放。

### 实际验证

| 层级 | 当前证据 |
| --- | --- |
| 编译 | Xcode 27.2（27B52），实际 Swift 6 对象编译与完整 App／测试目标链接通过，`FloeIntegrationAcceptance`，Debug arm64 iOS Simulator，6 jobs。 |
| 音乐组件 | JSON 契约 15 项、片段操作 13 项、音色／实际 PCM 10 项定向测试通过；41 个音色有真实音频输出证据。 |
| App 合同 | 13 个不同用例通过：音乐 4、生物原件授权／删除恢复 1、LaTeX App 接入 3、权限边界 5；以 xcresult 的实际用例记录计数。 |
| 30 秒作品 | 已注册 `studio.create/read/edit/run` 创建 100 BPM、960 PPQ 原件；15,360 ticks／3 个原音符片段追加至 48,000 ticks／51 个音符，保存后重新从原生仓库加载相同内容。另验新增片段保留旧片段。 |
| 实际音频 | 48 kHz、双声道 Float32 WAV，各 1,440,000 帧，严格 30.0 秒。非静音峰值 0.2457706332；静音峰值 0。逐 PCM 检查数值有限，文件大小与工具回执一致。 |
| 音乐界面 | 同一复用 iPad，横竖布局：唯一顶部助手；音色分类／应用／撤销；试听状态及关闭；MIDI 操作和和弦模板保存／撤销。没有声学听感或真实 Pencil／鼠标硬件结论。 |
| 建筑界面 | 最新 App 候选中四个专业页面分别打开、关闭并回到同一 CAD；最终回到空间。未重新执行数值精度矩阵。 |
| 清理 | 9 个精确身份确认的自有合成项目通过 App 批量移到最近删除（7＋2），包括已经打开关闭的 CAD，确认租约已释放。独立恢复包逐文件核验；保留其他项目，恢复列表视图／名称排序，结束后复用模拟器已关机。软删除本身不计释放空间。 |

WAV SHA-256：

- 非静音：`19d204411e42d0450e3f18f2271d29e6104c0a90ccda8437465bc3f5c0cb06a6`
- 静音：`28a1a6dbb4dd6219e2e0b475e41f3603f16657f8f831ff507e5510d32ae57de0`

实际构建命令使用显式 `DEVELOPER_DIR`、内部 SSD DerivedData、固定依赖与复用模拟器锁：

```sh
xcodebuild -project FloeAgent/FloeAgent.xcodeproj -scheme FloeIntegrationAcceptance \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$FLOE_DERIVED_DATA" -clonedSourcePackagesDirPath "$FLOE_SOURCE_PACKAGES" \
  -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile -jobs 6 \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO build-for-testing
```

最新构建检查点 `app-build-27` 基于 `51d6a14b0125924eb42fcb5e89e6d1b0a824e520` 加本次精确源码快照。构建中独立预研的两个未链接文件发生变化，原始全局源码检查 `sourceUnchanged=false` 保留；另核对项目、依赖清单与实际日志，确认它们不属于此 App 构建图，实际使用的 2,336 个文件哈希不变。未通过重试掩盖漂移。保存的 App ZIP SHA-256 为 `60333e550a5bcad26636babd1d50edcd0a55ce53d4e667a3fa64a63c1191b1b0`，主可执行文件为 `b46d41d99202dd11cb399a211dcc2cfecbc087fa9140044111a389bddcaab264`。

提交整理时仅移除了 5 个 LaTeX 源码／配置文件末尾多余的空行，逐字节确认除此以外不变；上游许可证排版和补丁上下文原样保留。原始空白检查结果与例外核对单独保存，没有为末尾空行重复运行无关编译或测试。

### 原失败与未完成边界

第一次 App 合同命令遗漏 Swift Testing 选择器括号：仅 8 个 XCTest 实际执行，不把命令退出 0 当作其余用例成功。修正选择器后，3 个新音乐用例暴露测试夹具错误：把 master 传给辅助总线操作；改为真实 `setMasterStrip` 并增强主输出状态断言后这 3 项通过。原日志、断言、xcresult 与首次建筑导航环境丢失截图均保留，已通过的无关用例没有反复重跑。

LaTeX 已编译并通过上述 App 身份／授权合同，实际 App 的完整 Linux→XeLaTeX→PDF 与模型往返仍待验。完整 PCB／原理图保持 [N19 原范围](../../FLOE_PCB_EDITOR_IMPLEMENTATION_PLAN.zh-CN.md)：当前核心与 DRC 的 53 个组件用例通过，不代表编辑器已接入 App。GIS／乐谱／字体由独立负责人继续，不作为本检查点的完成条件。物理 iPad／音频硬件、外部模型账户、生产安装包均未由本次证据证明。

## English

The registered App music tools now accept explicit MIDI insert/update commands, preserve existing notes with append mode, validate field paths before committing, and publish complete examples and native preset/template capabilities. Exact Codable compatibility and the existing ownership, revision, approval and failure boundaries remain in place. WAV/MP3 rendering accepts `tailFrames: 0` for exact content length and respects the saved mix, including master mute.

Actual App tests saved and reopened a synthetic 100 BPM / 960 PPQ piece while retaining its three original notes. Both exported WAV files contain exactly 1,440,000 stereo frames at 48 kHz (30.0 seconds); the audible fixture has a finite nonzero peak and the muted fixture remains silent. The original user payload was unavailable and the user's composition was not modified. The workbench also gained 41 native synthesized presets and MIDI actions/templates, with one assistant entry.

The actual arm64 Simulator App and test targets compiled and linked with Xcode 27.2. Thirteen distinct App contract cases passed; original selector/fixture failures and a Building navigation failure were retained and corrected. Canonical iPad UI checks covered music editing and the four Building professional pages with return to the same CAD original. Nine owned fixtures were soft-deleted through the App after verified recovery export; the Simulator was shut down.

This is a local Debug checkpoint, not a new TestFlight delivery or a replacement for frozen Build 325. LaTeX's full in-App Linux/PDF cycle, the complete PCB editor, physical audio/input behavior and external-account behavior remain separate unfinished scopes.
