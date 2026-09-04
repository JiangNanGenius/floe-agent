## Floe Agent 1.4.87 (Build 118)

### 简体中文

- 修复普通对话画中画状态机：前台不主动弹出系统悬浮窗，离开应用时才启动，并保持真实媒体时间线与生命周期。
- 修复 VNC 工具链：尊重用户明确指定的 SSH 修复路径，保存端点后执行 `connect`，真实连接成功前禁止 `observe` 和输入，同一失败不再无限重试。
- 修复 Infinite Canvas 多参考图上下文、模型能力上限、四结果四连线、原子保存、固定网格布局与连接端口拖拽。
- 加固 Harness 与时间线：长思考中的 JSON、代码和工具样符号不再被误判，最终答复与思考步骤保持正确顺序。
- GitHub 设置支持 OAuth Device Flow 直接登录和 PAT 备用方式；令牌进入 Keychain，不嵌入 Client Secret。
- 记忆整理提供“规则 + 审核”和“完全交给模型”两种模式，变更前检查既有事实、冲突、环境和版本变化。
- 新增受限只读的 ping、traceroute/tracepath、DNS 查询和 TCP 端口探测；每轮模型运行都会收到本地时间、IANA 时区与 UTC 偏移。
- 修复媒体专用审批模型导致的配置保存失败。

App Store Connect transport 已接受 Build 118。Apple `VALID` 处理状态和内部 Floe QA 测试组可见性单独验证。实体 iPad 上的系统画中画、真实 VNC 坐标一致性和多参考图服务商行为仍需手工验收。

### English

- Fixed the ordinary-chat Picture in Picture state machine: the system floating window is not presented while Floe is foregrounded, starts only after leaving the app, and uses a real media timeline and lifecycle.
- Fixed the VNC workflow: Floe honors an explicitly requested SSH repair path, connects after saving an endpoint, gates observation and input on a real connection, and stops unchanged retries.
- Fixed Infinite Canvas multi-reference context, model capability limits, four-result/four-edge output, atomic persistence, deterministic grid layout, and connector dragging.
- Hardened the Harness and timeline so JSON, code, and tool-like symbols inside long reasoning are not misclassified and final answers stay in the correct order.
- Added GitHub OAuth Device Flow sign-in with PAT fallback. Tokens are stored in Keychain and no client secret is embedded.
- Added review-first and model-managed memory organization modes; both inspect existing facts, conflicts, environment, and version drift before mutation.
- Added bounded read-only ping, traceroute/tracepath, DNS lookup, and TCP probing. Every model run receives the local time, IANA time zone, and UTC offset.
- Fixed configuration saving when an approval model supports media but not text.

App Store Connect transport accepted Build 118. Apple `VALID` processing and visibility in the internal Floe QA group are verified separately. System PiP on a physical iPad, real VNC coordinate consistency, and provider-specific multi-reference behavior still require manual acceptance.
