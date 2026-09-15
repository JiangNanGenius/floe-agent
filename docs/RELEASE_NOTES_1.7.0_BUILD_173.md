# Floe Agent 1.7.0 (173) — repair candidate

Preparation draft. This candidate has not been uploaded to TestFlight or published as an App release. The final source, upload SDK, binary hashes and acceptance results must be attached at delivery. Build 172 remains the last delivered internal build.

### 简体中文

本轮重点修复执行环境、包安装和手记交互。

- 手记助手使用独立的持久会话归属，不再出现在普通聊天、搜索和归档列表中。按旧文档绑定修复已有记录，保留消息；普通对话仅引用手记资料不会被改为专属会话。

- Shell、Python 与真正的 Node.js 使用明确的会话／项目环境。补齐 Python 输出流接口和 Node 安装所需目录，pip 复用已内置的原生依赖，避免将它们误判为必须重新安装的桌面二进制。
- 内置经过 iOS 构建的 lxml，并接通 python-docx、python-pptx 等常用文档包。npm/pnpm 可按环境选择，安装失败保留上一个依赖版本；两个管理器共享该环境的软件源设置。
- Node 与 Python 可启动持续的本地预览服务。服务不跟着设置页或浏览器预览关闭；提供状态、日志、预览、停止和重新启动，并在任务／环境删除时等待所属服务结束。
- APT 的正常入口回到 Shell。修复参数解析和安装／卸载路径，旧 Agent Tool 仅保留兼容。第三方源的 TLS、签名策略和载荷摘要分别处理，不将签名失败自动降级为无签名成功。
- 文档助手不再生成内部开场消息，调整 iPad 面板与输入区尺寸。Office 精简重复顶部栏。手记搜索采用紧凑结果行，按搜索键收起键盘；画笔使用“透明度”，0% 为实心，保留原有笔迹参数。
- 排队引导消息支持在插入前撤回或编辑。加强任务清单和进展提示规则，增加日志等级设置与可保留的崩溃摘要。

测试重点：iPad 横屏正文搜索、Office 保存重开、黑笔／荧光笔参数、pip/npm/pnpm 安装后实际使用、HTTPS、循环／管道／stdin、重复执行与取消、两个项目中的预览服务和删除归属。请使用文档副本。

已完成候选的完整 App 运行回归为 169/169；最终 173 的双端界面与完整验证另行记录。Qwen 的 Mac 冷加载与长输入诊断通过。9 月 15 日取得的 iPad 报告确认 MLX 在预处理阶段进入默认致命错误回调；候选已增加专用错误捕获，底层图计算故障及真机恢复仍待验证。同批 PDF 闪退已定位为真机包混用两套 PDF 引擎；候选修正连接顺序，并在 IPA 打包时校验实际函数绑定。官方 APT 发布、完整原生 npm／WASI 包及全部媒体模型仍有未完成项，不列为已交付能力。公开 Beta 材料由用户审核后另行提交，演示用密钥不提供给审核人员。

### English

This candidate repairs environment ownership, package installation and Notes interaction. Python's bounded output now provides the standard stream interface, Node installs prepare owned working directories, and pip reuses compatible bundled native dependencies. The iOS lxml integration enables common Word and presentation libraries. Environment package controls distinguish npm and pnpm and retain the previous installation on failure.

Node and Python preview servers have an explicit owned lifetime, status, logs, preview, stop and restart controls. Closing a preview does not stop its server. Owner deletion waits for its workers. APT is normally invoked through Shell, with legacy Agent calls retained only for compatibility; TLS, repository signature policy and payload checks remain separate.

The document assistant starts without internal setup chatter and uses a refined iPad panel. Office removes duplicate header chrome. Notes body-search results use compact rows and dismiss the keyboard on Search. Brush transparency uses 0% for solid ink while preserving stored alpha. Pending guidance can be withdrawn or edited before insertion; checklist/progress instructions and diagnostic controls are improved.

Use backed-up documents to check iPad landscape search, Office save/reopen, pen/highlighter settings, actual pip/npm/pnpm use, HTTPS, Shell loops/pipelines/stdin, repeat execution, cancellation and preview-server ownership across projects. A preceding candidate passed 169/169 native App regressions; final build 173 qualification is recorded separately. The September 15 iPad reports show MLX prefill errors reaching a fatal callback. Scoped error handling is added; the underlying graph error and device recovery remain unverified. A separate PDF crash was traced to mixed Office/PDFium bindings in the device binary; the candidate corrects linker order and verifies actual bindings during IPA packaging. Complete native npm/WASI packages, the official APT publication and full media-model delivery remain incomplete. Public Beta submission is separate and awaits the owner's review; demonstration credentials are excluded from reviewer access.

### Qualification scope correction

The `9e4434ca` full-App run passed dedicated Notes conversation migration and both simulator Notes interaction cases. It recorded 170/171 App regressions passing; the remaining assertion read asynchronous service stdout before it arrived. HTTP readback, cancellation and preview revocation passed. The follow-up waits for log delivery while preserving the assertion. [Screenshots and original result summary](evidence/floe-1.7/build172-repair/notes-9e4434ca/README.md) are retained. A subsequent source also qualifies actual local Keychain CRUD under Xcode simulator signing before any paid demonstration credential is configured.

Native Office is linked only in iphoneos builds. Simulator Notes qualification now explicitly skips the native Office case, requires the remaining PDF/import/search case to pass, and emits `nativeOfficeAccepted: false`. The native Office test remains enabled on device. This is a recorded coverage gap, not an Office pass; Build 173 native Office acceptance remains pending. Notes assistant ownership is now durable, with idempotent legacy binding reconciliation and protection against streaming updates reinserting dedicated sessions into ordinary chat lists.

Cloud diagnostic [34934175018](https://github.com/JiangNanGenius/floe-agent/actions/runs/34934175018), source `caa72d52596f140413c89930e4e0c4369545daa0`, passed the MLX error callback containment probe and three actual Qwen generations. Cold load: 8.00 s; generation wall times: 7.72 s, 0.84 s, and 44.62 s for 5,773 input tokens. MLX peak: 2,780,554,736 bytes. This is a macOS diagnostic host, not iPad acceptance; see [machine-readable evidence](evidence/floe-1.7/build172-repair/qwen-error-guard-caa72d52.json).
