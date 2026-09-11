# Floe Agent 1.6.5

> 2026-09-11。快速迭代修复版：兼容模式工具名（含 tools_list 等发现类工具）全链路修复。
> English summary follows the Chinese section.

### 简体中文

## 修复

- **兼容模式下所有工具名（含 tools.list/tools.search 等发现类工具）仍不可用**：
  - 根因：反向映射的"全集"只含运行权限上限，而 tools.list / tools.search（及计划模式提交工具）只存在于当次请求的 schema 里，因此模型以 `tools_list` 这类下划线名调用时无法还原为 `tools.list`，被拒为"未知工具"。
  - 现在反向映射全集 = 运行上限 ∪ 当次请求的全部 schema，并按大小写不敏感归一化——`tools_list`、`workspace_listdirectory` 等漂移拼写均可还原。
  - **兼容模式下 tools.list 直接返回下划线工具名**（`name` 字段即线上拼写，翻页游标 `nextAfterName` 同样为下划线）；tools.search 的加载结果、延迟列表、查询回显、工具索引提示、schema 驱逐提示与前置条件提示全部改用下划线名，模型无需再做点/下划线换算。

### English

## Fix

- **Compat mode: underscored tool names (including discovery tools) still failed**:
  - Root cause: the reverse-mapping universe only covered the run ceiling, while `tools.list`/`tools.search` (and the plan-submit tool) exist only in the current request's schemas; `tools_list` could not be restored to `tools.list` and was denied as an unknown tool.
  - The universe is now the union of the run ceiling and all offered schemas, matched case-insensitively, so drifted spellings like `tools_list` or `workspace_listdirectory` resolve.
  - **In compat mode `tools.list` now returns wire-spelled (underscored) tool names directly**, including `nextAfterName` cursors; tools.search results, deferred lists, query echoes, the discovery index, schema-eviction notes and prerequisite notes all use the same underscored spelling.
