# 建筑项目数据设计原型

当前开发入口是[独立组件与接入合同](../../../FloeAgent/Modules/FloeInteriorKit/README.md)，实际运行状态以[本轮验证记录](../../qualification/FLOE_BUILDING_PREDEVELOPMENT_20261113.zh-CN.md)和[基础联调门槛](integration-candidate-v1.json)为准。全部需求保留在[28项QA](../../FLOE_BUILDING_EDITOR_REQUIREMENTS_QA_20261112.zh-CN.md)与[12条整体验收场景](closure-scenarios-v2.json)。

下面的v0文件及[native-core-gap-v2调查](native-core-gap-v2.json)保留各自调查时点，是设计输入；其中旧测试数量、缺口和状态不能替代上述当前验证记录。v0 SQL不作为现有GRDB库的迁移脚本使用。

这是本地数据合同与资源／转换方案的可执行预研，不是 App 数据库迁移、可导入的 Floe 工程或完整建筑数据库。

- [实施蓝图](../../FLOE_BUILDING_EDITOR_CORE_REUSE_AND_DATA_BLUEPRINT_20261112.zh-CN.md)：保留自有二维／三维核心的转换分层、成熟项目选择和实施包。
- [独立组件实测](../../qualification/FLOE_INTERIOR_COMPONENT_20261112.zh-CN.md)：柜体、原生实体、样图及上游墙面算法的实际结果；样例方向复查已过，完整施工图与 App 仍未验收，STEP 移动修复只在私有副本验证。
- [制造与排板预研](../../FLOE_INTERIOR_MANUFACTURING_REUSE_20261112.zh-CN.md)、[制造合同草案](manufacturing-contract-v0.json)：从 OpenCutList 追到 MIT PackingSolver 内核，以及板件坐标、封边、余量、木纹、原板和分阶段验证；尚未运行优化或生产流程。
- [真实家具目录与品牌库调研](../../FLOE_INTERIOR_FURNITURE_INTAKE_20261112.zh-CN.md)：175 条 CC0 目录检查与 SQLite 暂存；新增自有库／上游取得／更新建议、Blum 与 Salice 官方接入路径，以及实际取得的 Hettich STEP 包。品牌原生接入和制造规则尚未验证。
- [schema-v0.sql](schema-v0.sql)：项目资料、类型化观察、采用决定、来源、版本化资产与实例、操作及检索结构。
- [forms-v0.json](forms-v0.json)：8 类内部表单，共用中英字段、单位和验证规则。`nativeActions` 是拟议适配动作，不代表现有工具已全部提供。
- [reuse-sources-v0.json](reuse-sources-v0.json)：本轮读取的源文件、摘要、候选许可、固定快照与未完成验证。
- [asset-sources-v0.json](asset-sources-v0.json)：家具／材质来源和逐项入库所需信息；已对一个 CC0 包离线检查，其余仍是候选，没有 App 成品库。
- [smart-home-bom-v0.json](smart-home-bom-v0.json)：智能家居料单的来源定位、字段、数量／包装／业务状态、设备匹配与 AI 整理／采用合同；尚未实现格式读取和 App 工具。
- [building-systems-workbenches-v0.json](building-systems-workbenches-v0.json)：智能家居／暖通工作台、总线和供电图例、AP 估算及三维照明的追加设计与候选来源；不是已验证的仿真服务。
- [drawing-catalog-v0.json](drawing-catalog-v0.json)：室内装修优先的 7 组、41 种图纸／表格目录，包含必要输入、生成方式和范围；详见[出图方案](../../FLOE_INTERIOR_DRAWINGS_AND_CABINET_DETAILING_20261112.zh-CN.md)。这是生成器设计目录，未加入此前 24 项数据库行为检查。
- [check_design.py](check_design.py)：使用合成资料、参数记录和 SQLite 检查结构、查询、修改及备份行为。

运行时使用一个新的任务自有输出目录，脚本会保留已有数据库：

```sh
python3 docs/design/building-project/check_design.py \
  --output-directory "${TMPDIR:-/tmp}/floe-building-design-$(date +%s)"
```

第一阶段定稿结果位于 `building-data-design-20261112/v0-final/`：24 项检查通过，8 类表单定义有效。目录包含设计数据库、合成来源文本、合成参数配方和 `verification.json`。`adopted_fields` 可查看厨房当前采用 4000 mm，`observation` 保留 3600／4000 两条依据，`adoption` 保留改变决定的链。

随后为资产检索增加 `search_entry.asset_version_id` 外键，24 项基础检查在新的 `v0-asset-search/` 目录再次通过；旧数据库未改写。真实素材目录另建暂存数据库，并核验了资产关联检索、未知外键拒绝、6 条资源问题筛选和备份重开，详见上方家具目录记录。这个草案不是生产 schema 升级脚本。

基础 `check_design.py` 原型不写真实用户工程，使用合成素材，配方未生成几何；测试不证明原生 GRDB、SwiftUI 表单、识别／家具原生导入、转换内核、AI 推理、跨 CAD／数据库事务或设备精度。后续真实素材目录与柜体几何另有独立证据。完整领域拓扑、空间／构件的原生操作、复合材料／制造规则、生产迁移和资源预算仍须在对应实施包中落实。

`asset_release` 仅表示项目内部资源完成入库，未指向网站发布。当前数据库未完成内容级模型／纹理验证，正式入库由服务校验资源后创建该记录。表单、工具与后台导入均通过相同服务；AI 不直接执行任意 SQL。
