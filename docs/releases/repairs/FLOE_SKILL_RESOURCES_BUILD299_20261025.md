# Floe 1.7.58（299）Skill 配套资源 / Skill bundle resources

日期 / Date: 2026-10-25.

## 修改 / Changes

读取已安装 Skill 时，将该版本完整的脚本、模板和参考文件提供给任务所绑定的 Linux 工作区。资源路径携带明确的环境与任务身份；复用前核对实际文件内容，发布采用原子写入，取消和失败保留已有有效资源。列表和搜索不会执行脚本，也不扩大工具权限。

Reading an installed Skill now delivers its pinned scripts, templates and references to the task's bound Linux workspace. Reuse verifies actual bytes; staging preserves cancellation, ownership and existing permissions. Listing and searching do not execute scripts.

## 验证 / Verification

- Xcode 27.1（27A9275）：完整 App 与 AppTests 的 Swift 6 Simulator 对象编译通过；iPhoneOS 27.1 Release 归档通过。30 项相关 App 宿主测试通过，0 失败、0 跳过。
- 保留原始失败：新增测试的全局辅助函数重名，以及负向环境绑定夹具将所有环境映射到同一工作区。两处均修正测试夹具，未放宽断言；最后一次编译及 30 项测试全部通过。
- 授权的 M4 iPad 已从 TestFlight 安装并启动 299，核对实际版本及发布说明；原先安装的外部 Skill 保留。
- 官方 `jupyter-notebook` 实际使用自带的 `scripts/new_notebook.py` 和 `assets/tutorial-template.ipynb` 生成 `check.ipynb`，未重建替代脚本或模板，未安装额外包。设备读回的 11 个配套文件与原始安装输入逐字节一致。
- 实际产物为 2,500 bytes、7 个单元格、Notebook 4.5，首行 `# Tutorial: FloeImportCheck`；SHA-256 为 `b84d79199d89dead91b0040c5c133bed172e47ee4d786fe4b490ace02498ee6e`。聊天返回的附件已点开，系统预览展示文件信息；不宣称具备 Notebook 内容渲染器。
- 验收后在 Device Hub 停止共享，独立核对回到 `View Screen`、键盘捕获关闭。复用的 Simulator 已关闭，应用与数据保留。

All 30 selected App-host tests, full Swift 6 compilation and the device archive passed. On the authorized iPad, the original upstream script consumed its bundled template and generated the verified notebook. All 11 staged input files matched device read-back. The attachment opened in system preview; native notebook rendering is not claimed. Screen sharing was explicitly disconnected afterward.

## 交付 / Delivery

- 不可变源码 / Immutable source: `9e5d49ba469d2d47011e4a70f23e02e8862bd93b`。
- 标签 / Tag: `v1.7.58`；annotated object `b32d268da8f3b36462c70e00d48f80b65b8b3aa4`，未移动标签。
- [签名及内部交付 40187120820](https://github.com/JiangNanGenius/floe-agent/actions/runs/40187120820)：Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`，中英文说明核对通过，真机安装与启动另行确认。
- publictest1 只提交一次；重新打开列表回读为“正在等待审核”、90 天有效期，关联 Floe QA 与 publictest1。外部可安装尚未确认。
- [稳定无签名 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.58)及[同次发布、等待完成的 Feather 任务 40189556319](https://github.com/JiangNanGenius/floe-agent/actions/runs/40189556319)通过。独立下载核验源码、标签、真实 arm64 iOS 可执行文件、latest、摘要及在线 Feather 的实际版本、链接、源码和摘要。
- `Floe-Agent-1.7.58-build299-unsigned.ipa`：812,299,112 bytes；SHA-256 `c1d808d76ee8152e43c4ed9c52a58a5875d034ef2de10ed0c50317ff8f882371`。

Internal TestFlight and verified unsigned/Feather delivery are available. Public TestFlight awaits Apple review. Both distribution routes reused the saved exact-source device artifact and matching symbols.

## 边界与清理 / Limits and cleanup

299 只修复 Skill 资源传递；不包含新报告的空闲定位释放修复，也不把本次 Skill 验收当作语音听感、真实麦克风或定位停止的证明。

已移除本轮 Simulator／Release 编译缓存、重复归档、App 副本及传输暂存；保留可恢复原包、14 份匹配符号、无签名包与摘要、原始失败及验证材料、既有回滚版本和模拟器数据。正式 App Store 275、其他工作树及用户数据保持原状。

This build does not change idle-location cleanup or establish new voice acceptance. Scoped cleanup preserves recovery artifacts, symbols, installable delivery, original evidence and user data.
