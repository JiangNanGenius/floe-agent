# FloePrintKit

打印工作台使用的 Swift 6 输入、配置、产物、逐层预览及切片生命周期合同。[English](README.md)

App 工作台位于 `FloeApp/Space/Printing`，离线 WebKit 适配器位于 `FloeApp/Resources/Printing`，使用 `ThirdParty/KiriMoto` 的固定上游子集，不暴露通用脚本运行工具。原独立资格宿主保留在 `Qualification/Printing`。

- 不可变毫米三角网格与有界二进制 STL 导入。
- App 会话保存多盘、多对象、版本守卫编辑、变换及撤销。
- `PrintMachineConfiguration`：Cartesian/CoreXY/i3/Delta/SCARA 固件结构描述，成型尺寸、床原点、喷头及工具偏移、自定义纯文本 G-code，以及树脂平台、升降和曝光布局。
- `PrintInput`：几何、工艺、完整机器配置、固定引擎及适配版本 `floe-print-app-4` 共同进入内容指纹。
- `PrintArtifact`：按实际机器和工艺检查 G-code/CTB 产物；`PrintGCodePreview`、`PrintCTBPreview` 读取已保存结果进行逐层播放。
- `PrintSlicingService`：独立于编辑器生命周期持有串行后端与取消边界。

编辑器以打印床中心为 XY 原点、平台面为 Z=0。FDM 输出只应用一次床原点、喷头和工具偏移，保留笛卡尔坐标；电机混合由固件负责。自定义 G-code 只做固定占位符字面替换，不求值表达式。树脂方向和镜像/旋转用于实际切片布局，升降和曝光参数写入 CTB；实际 Z 电机方向由打印机配置控制。

当前每盘使用一个工具，输出 G-code 或 CTB v3。同盘多工具换色、支撑绘制、排液孔、网格修复、3MF 项目往返和特定打印机网络推送尚未完成；系统共享菜单导出完整文件。通用预设不代表厂商硬件认证。

源码编译、App 页面/布局、切片运行及物理打印是不同证据。已有 FDM/CTB 资格材料保留，不据此认证新增机器配置或硬件。按当前仓库约定选择相关编译和验收。

Floe 代码为 MPL-2.0；上游及依赖许可和本地补丁须保留。独立解码器仅用于资格检查，不链接进 App。
