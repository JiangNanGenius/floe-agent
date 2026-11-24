# Floe Agent 1.8.79（400）

## 简体中文

- 减少长回复刷新时的重复解析，降低流式输出和回看历史回复的渲染开销。
- 减少会话和任务列表在状态未变化时的界面刷新。
- 优化长文本的用量估算，兼容中英文混排和表情。
- 减少工具名称查找和工具列表排序的重复开销，加快工作区目录筛选。

## English

- Reduce repeated parsing during streaming and when revisiting long answers.
- Avoid refreshing conversations and task lists when their displayed state has not changed.
- Estimate usage for long drafts more efficiently, including mixed languages and emoji.
- Reduce repeated tool lookup and catalog sorting work, and filter workspace directories more efficiently.
