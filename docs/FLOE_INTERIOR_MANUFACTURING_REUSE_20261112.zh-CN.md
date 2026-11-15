# 室内组件：柜体制造数据与排板内核预研

日期：2026-11-12。状态：固定源码调查与数据合同设计，未编译排板引擎、未生成可生产数据。继续复用 Floe 自有二维／三维 CAD；本轮找到的是柜体生产准备和排板的中间层候选。

## 一、追到实际内核，而非只参考功能页面

OpenCutList 的固定快照 `1ef3e14c896171eed8cd77ede440c7f5563e943e` 包含 SketchUp Ruby 工作流和 C++ `Packy` 包装层。Ruby 调用开始、推进及取消接口；CMake 链接一维、矩形、贯通切割矩形和异形四类 PackingSolver 库。[工作流源码](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension/blob/1ef3e14c896171eed8cd77ede440c7f5563e943e/src/ladb_opencutlist/ruby/worker/cutlist/cutlist_packing_worker.rb)、[C++ 构建](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension/blob/1ef3e14c896171eed8cd77ede440c7f5563e943e/src/ladb_opencutlist/cpp/lib/Packy/CMakeLists.txt)。

`Packy/extern/CMakeLists.txt` 指向 `lairdubois/fontanf-packingsolver` 的确定版本 `f1e2baa84e224f2f19a4121ad77bc9428e6cb146`。[依赖绑定](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension/blob/1ef3e14c896171eed8cd77ede440c7f5563e943e/src/ladb_opencutlist/cpp/lib/Packy/extern/CMakeLists.txt)。这提供了具体算法候选，无须把整个 SketchUp 编辑器搬入 Floe。

| 对象 | 已核对 | 本轮决策 |
| --- | --- | --- |
| OpenCutList 工作流和 Packy 包装层 | 仓库 GPLv3；Ruby 使用 SketchUp 类型；Packy 当前构建为共享库 | 参考板件、材料和排板合同；尚未批准复制或作为 App 依赖 |
| 固定 PackingSolver fork | MIT；C++ 库；明确支持多类排板约束 | 优先验证其独立算法接口，单独核对依赖及 Apple 封装 |
| 当前 FloeInteriorKit | 自有稳定板件与材料版本；可生成真实 CAD 实体 | 给求解器提供明确的板件／原板／工艺快照，结果映射回原板件身份 |

许可分别见 [OpenCutList LICENSE](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension/blob/1ef3e14c896171eed8cd77ede440c7f5563e943e/LICENSE) 和 [PackingSolver LICENSE](https://github.com/lairdubois/fontanf-packingsolver/blob/f1e2baa84e224f2f19a4121ad77bc9428e6cb146/LICENSE)。这是来源事实和接入建议，不是已完成原生封装或分发许可评审。

该 fork 的构建还会取得 optimizationtools、shape、树搜索、列生成、HiGHS 等依赖；即使关闭部分求解器选项，外部 CMake 仍有无条件取得 HiGHS 的代码。必须先收敛需要的目标、依赖与许可证，再核验设备／Simulator 静态链接、体积和运行预算，不能宣称“一个头文件即可接入”。[依赖源码](https://github.com/lairdubois/fontanf-packingsolver/blob/f1e2baa84e224f2f19a4121ad77bc9428e6cb146/extern/CMakeLists.txt)。

Packy 当前 C 接口返回共享 `std::string` 的借用指针，并保存进程级运行表。若评估该包装层，需串行调用并立即复制结果；若直接连接 PackingSolver，则另设由现有服务拥有的作业生命周期与明确错误边界。开始／推进／取消三个函数的存在不等于取消、线程安全和内存已经验收。[接口实现](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension/blob/1ef3e14c896171eed8cd77ede440c7f5563e943e/src/ladb_opencutlist/cpp/lib/Packy/src/packy.cpp)。

## 二、制造材料必须有独立于贴图的含义

固定源码的材料属性明确保存木纹、长度／宽度／厚度余量、标准规格、逐边扣减、密度和价格；板材、实木、型材、封边、五金和饰面分开处理。[材料属性源码](https://github.com/lairdubois/lairdubois-opencutlist-sketchup-extension/blob/1ef3e14c896171eed8cd77ede440c7f5563e943e/src/ladb_opencutlist/ruby/model/attributes/material_attributes.rb)。

当前在线文档还出现了新的 Machining 类型；上述固定源码没有该类型，不能将在线说明当作这个快照已实现的证据。资料入库需同时记录文档访问日期与实际代码版本。[当前材料文档](https://docs.opencutlist.org/features/applying-materials)。

Floe 的材料定义宜分为渲染外观与工程／制造参数，通过版本关联。木纹贴图方向不自动等于板材可旋转方向。墙体复合层、板件基材、贴面、封边和五金可共用资源检索，但分别使用适用的领域字段。

| 记录 | 必须明确的数据 | 未知时行为 |
| --- | --- | --- |
| 板件局部坐标 | 原点、U／V／厚度轴、正反面、实际到模型变换 | 可以显示设计模型；停止依赖加工面的自动结果 |
| 材料版本 | 基材类别、实际厚度、标准尺寸、批次／供应来源及适用规则 | 不用名义厚度或贴图名字代替实际参数 |
| 木纹和对纹 | 沿 U／V、无方向或未知；允许旋转、镜像及成组连续对纹 | “未知”不等同于“无方向” |
| 逐边封边 | 稳定边身份、材料版本、有效完成厚度、是否扣减、处理顺序 | 不按“所有边 1 mm”等隐藏默认值开料 |
| 饰面与加工面 | 正反面版本、饰面厚度、可加工面及基准边 | 不从摄像机朝向判断加工正面 |
| 加工规则 | 余量的总量／逐边定义，锯缝／刀径、修边、连接与五金规则版本 | 仅生成不冒充生产数据的设计成果 |

对于非矩形板，边身份必须关联明确的轮廓段；板件改形后无法对应的边／孔进入待修复，不将“第 3 条边”或瞬时 BRep 编号当成永久身份。

## 三、尺寸要分层记录

成熟工作流在排板时使用经过余量和封边规则处理的原料尺寸，木纹限制影响旋转。[排板说明](https://docs.opencutlist.org/features/parts/parts-list/cutting-diagrams)。Floe 应明确保存三个量：

1. **设计完成包络**：安装后需要达到的尺寸，说明是否已经包含封边／饰面。
2. **基材完成尺寸**：按明确构造和有效封边厚度扣减后的板芯尺寸。
3. **开料毛坯尺寸**：在基材完成尺寸上按工序加入已声明余量。

示例仅作数据合同说明：假定完成包络为 600 × 400 × 18 mm，明确包含两条 U 端封边，各有效完成厚度 1 mm，余量为 U 总量 2 mm、V 总量 2 mm，则基材为 598 × 400 × 18，毛坯为 600 × 402 × 18。这里每个数值都是合成假设，不是厂商推荐或当前柜体生成器已经采用的构造。

如果当前 CAD 板件代表基材本身，不能再次按包络扣减。若尺寸基础、有效厚度或工序顺序未明确，计算进入待补。当前 `FloeInteriorKit` 的简单矩形实体与设计 CSV 没有这些完整规则，`manufacturingVerified` 继续为 false。

## 四、排板结果还需要核验

PackingSolver 固定 README 列出贯通切割约束、分阶段切割、修边、锯缝、旋转以及原板缺陷等能力；这属于候选能力声明，尚非 Floe 的运行证据。[固定引擎说明](https://github.com/lairdubois/fontanf-packingsolver/blob/f1e2baa84e224f2f19a4121ad77bc9428e6cb146/README.md)。接入包应按以下顺序验证：

- 以明确版本的板件、材料／批次、实际原板尺寸、余料数量和工艺参数建立输入快照；不能默认为库存无限。
- 按材质、厚度及工艺分组，保留逻辑板件 ID 到求解器 item ID 的对应；被放不下的部件逐项列出，不截断。
- 每个结果独立核对包含范围、重叠、边距、刀缝、允许旋转、纹理／镜像和重复／漏件；选择贯通切割时还要核对切割树。
- 记录使用的原板、可保留余料、切割长度／次数与目标值；取消或超时可保留有明确验证状态的候选结果。
- 锁定同一次输入和配置的输出；工程改动后标为失效，不覆盖已交付的排板版本。

布局可行不等于孔位、五金开合、连接强度或机器程序均正确。分别记录尺寸准备、排板可行、安装避让、孔槽／五金规则和后处理器验证。库存采用／消耗由项目服务另做明确提交，不在一次优化试算中隐式扣库。

## 五、落地到项目资料系统

新增合同草案 [manufacturing-contract-v0.json](design/building-project/manufacturing-contract-v0.json) 记录上述字段、合成算例及未验收状态。它不是 SQL 迁移或工厂文件，不改变现有 24 项数据库原型测试的范围。

实施时将板件制造定义纳入不可原地改写的资产／配方版本，采用的材料与五金固定到确定版本；实例继续保存变换和局部覆盖。原始厂家文件、人工尺寸、AI 提取与最终采用值各有来源和决定记录。AI 可整理、提议和执行授权动作，缺少制造依据时创建待补项，不把外观网格自动升级为可生产柜体。

下一步原生排板验证应是独立、有界的实施包，首先跑小型矩形／贯通切割与不允许旋转样例，再决定是否扩展异形排板。当前没有把 OpenCutList／Packy／PackingSolver 下载到 App、运行优化或接入 CNC。
