# Floe Agent 1.7.14 — Build 255

## 简体中文

- 当任务要求调整 Linux 虚拟机核心数时，助手会先检查环境状态，再调用对应的启动或重启工具；避免普通命令先自动启动单核虚拟机。
- Linux 虚拟机资源池总计最多 4 核，单台最多 3 核；可按 3+1、2+1+1、2+2 或 1+1+1+1 分配。三核需要经启动验证的新镜像，旧双核镜像仍受双核上限约束。低内存设备继续遵守自身配额。
- 语音输入准备阶段显示加载状态；准备超时或启动失败后会退出并允许重试，过期的录音会话不会覆盖新会话。
- 调整语音波形对实际麦克风音量的响应，改善低音量说话时波形不动的问题。
- 修复手记导图给已有主题添加图片后，图片可能因旧卡片尺寸而不显示的问题。
- 限定手记图纸封面预览的 WebKit 等待时间，并对预览服务启动失败执行一次有限重试。

本构建另修复管道式交互 Shell 在高负载模拟器上输入后无输出的问题：改用标准输入脚本模式，并让输入输出泵使用独立的高优先级队列；关闭会话时等待原生运行门释放。

本构建还将 Notes iPad 自动化验收改为验证实际点击及菜单出现，避免高负载下读取空白辅助功能快照造成的误报。图纸封面渲染桥临时失败时会在新宿主上有限重试；滚动取消卡片任务后，已完成的真实封面会保留在按文档版本区分的缓存中。

云端模拟器验收还修复首次启动横屏状态同步，并延长首次模拟器数据迁移的有限等待时间。iPhone 导入菜单的自动化验收改用已确认在屏幕内的菜单行坐标点击，并继续检查导入页与编辑器实际出现。

请在实际 iPad 上验证虚拟机核心数、语音启动与波形。自动化测试和 TestFlight 分发不代表设备体验已验收。

## English

- When a task asks to change a Linux guest's core count, the assistant checks its status and uses the guest start or restart tool before a shell command auto-starts a single-core guest.
- The Linux guest pool allows up to 4 cores in total and 3 per guest, including 3+1, 2+1+1, 2+2 and 1+1+1+1. Three cores require the newly boot-verified image; older dual-core images remain capped at two. Low-memory devices retain their smaller quotas.
- Voice input shows preparation progress and exits a stalled or failed startup so it can be retried. A stale capture session cannot overwrite a newer one.
- The voice waveform responds more clearly to measured microphone levels at lower speaking volume.
- Fixes an illustrated Notes mind map topic sometimes hiding its newly attached image because its prior text-only card size was reused.
- Bounds WebKit waits for Notes drawing cover previews and retries a failed preview host once.

This build also addresses a piped interactive shell producing no output after input on a loaded simulator: it reads commands from standard input, gives its I/O pump a dedicated high-priority queue, and waits for the native execution gate to release when the session closes.

This build also verifies the Notes creation control by opening its menu in UI acceptance, avoiding a false failure from an empty accessibility snapshot under heavy load. A temporary drawing-cover bridge failure gets one bounded fresh-host retry, and a successful real cover survives cancellation of its scrolled-away library card task in the document-revision cache.

Cloud simulator qualification also synchronizes a first-launch landscape transition and gives first-boot data migration a longer finite wait. On iPhone, the import-menu UI test taps the verified on-screen row center and continues to assert that the import screen and editor actually open.

Please verify guest core count, voice startup and the waveform on a physical iPad. Automated tests and TestFlight delivery are separate from device acceptance.
