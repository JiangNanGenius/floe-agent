# FloePrintKit 独立预研发

R10 只修改源码：配套 JS 宿主使用任务独立网格快照，检查 Float32 转换造成的超差/特征压塌，明确固定原有 FDM 几何策略，并把原生合同的适配版本更新为 `floe-print-p0-2`。本次新增源码和用例未编译、未执行、未重新切片；原 p0-1 证据保留，但不作为当前改动通过的证明。模型顶点不做显示光顺。主线需同时收集三处源码、许可/资源及 `docs/`，完成 iPad 本地计算绑定和后续验证。

首批交付是切片输入、产物和任务生命周期的原生组件，配套真实离线切片资格宿主。完整需求见仓库 `docs/FLOE_3D_PRINTING_IMPLEMENTATION_PLAN.zh-CN.md`；本组件不修改生产 App 或根工程。

- `PrintMesh`：mm 三角面快照及严格二进制 STL 读取，拒绝不完整、非有限数、退化或超限输入。
- `PrintInput`：固定预设和数值覆盖项，冻结几何、引擎、适配器、配置版本与输出格式的内容指纹。来源身份/任务身份独立，不能用请求 ID 判断切片缓存有效性。
- `PrintRequestIdentity`：job/project/plate/revision，供主线既有文件、jobs 和工具服务绑定归属。
- `PrintSlicingService`：服务持有后端；同一可变引擎串行，取消后保留占用直到计算退出，丢弃取消/迟到结果。
- `PrintArtifact`：实际 G-code 或 CTB v3 的内容摘要、源指纹及结构检查。原生 CTB 检查只读取元数据和边界，完整逐层解码在独立资格工具中执行。

首批预设为原创建模校准用途的 Generic Marlin PLA（220×220×250 mm、0.4 mm 喷嘴）和 Generic CTB v3（120×68×150 mm、960×544）。它们不代表某厂商全部机型。坐标以打印床中心为 XY 原点，底面 Z=0；预设/工艺名称和版本必须随结果保存。

`PrintSlicingBackend` 是生产宿主的接入合同。真实计算代码在 `../../Qualification/Printing/EngineJS`，上游子集在 `../../ThirdParty/KiriMoto`。当前实际计算平台为 macOS Node；iPad WebKit 绑定、工作台原生 UI、3MF 项目往返、完整准备、多材料及具体品牌配置仍属于后续接入，不能据此宣称这些能力已经实现。

主线应同时收集本目录、KiriMoto 子集及 Printing 资格目录；不要只复制 Swift 模块便宣称已具有 iPad 切片。文件保存接既有归属和原子提交服务，UI/AI 共用领域命令，打印项目拥有独立撤销栈；不增加通用 Node/WASM 执行工具或第二套文件 authority。

原生检查：`DEVELOPER_DIR=<Xcode>/Contents/Developer xcrun swift test --package-path <本目录> --scratch-path <任务独立缓存> --jobs 6`。测试资源为实际生成的完整文件，测试后端仅验证服务合同，不冒充原生切片实现。iOS SDK 对象编译的命令和结果见仓库交付记录。

Floe 源码为 MPL-2.0。上游及依赖许可分别保留在 KiriMoto；Go 独立解码器只用于资格检查，不链接进 App。代表样本生成、回读及预览抽查无明显问题即可按对应范围交付，不要求用户逐台实打。
