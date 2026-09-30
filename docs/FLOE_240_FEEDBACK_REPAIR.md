# Build240 candidate: device feedback and real Office simulator verification

This is candidate evidence, not a Build240 release or device acceptance record.
Build239 remains the delivered version. Chinese Office text is fixed according
to the user's device feedback; PPT editor crashes remain unresolved.

## Reviewed changes

- Linux installation and guest state now drive the settings title separately.
  The service owns the short status cache, honors cancellation and invalidates
  stale reads after mutations. SMP admission uses the actual selected boot image
  and withdraws stale capability claims together with their manifest.
- Search requests to the two configured HTTPS provider endpoints use a narrow
  transport policy. Arbitrary URLs, custom endpoints and cross-origin redirects
  retain their network boundaries. VPN fake-IP resolution is a hypothesis,
  not a confirmed device root cause.
- Known context capacity is visible before generation; unreported usage shows
  a pending state rather than a measured zero.
- Office Kit callbacks retain their document/poll ownership and engine-thread
  lifecycle. Extracted regressions demonstrate source defects; they do not
  identify the user's native PPT crash stack.

## Native host evidence

[Host run 36710867608](https://github.com/JiangNanGenius/floe-agent/actions/runs/36710867608)
compiled and linked the patched native framework from
`16f0b0f6e1a324f4bc8ff4e7a07458751e093b2a`. The primary verified and retained
the whole `OfficeNativeHost.zip`, SHA256
`af875ca0e2031ecdc0bfc41a9e0c686a09e7e7d6d7824e418e49b2a18c1b9253`,
all 4780 runtime resources, the exact overlay provenance, and arm64 iPhoneOS
platform/minimum 26.0/SDK 27.0. The tracked host pin records these facts.
All runtime/device capability flags remain false.

## Cloud simulator gate

The new `office-floe-simulator.yml` consumes the genuine staged simulator engine
from a verified completed simulator build without rebuilding the core during
App qualification. [Run 36704184429](https://github.com/JiangNanGenius/floe-agent/actions/runs/36704184429)
failed after its core build completed: editor configure could not import
`lxml` through its effective `python3`. Dependencies had been installed into
the workflow's Python virtual environment, but the child process inherited a
different PATH. The failure artifact contains logs, not a reusable engine.
The repair must check the child interpreter before compilation and preserve a
completed-core checkpoint before downstream editor work. The full Floe App
PPT scenario has not run; no simulator render or runtime pass is claimed.

The scenario installs the actual Floe App on a fresh task-owned iPad simulator,
imports one pinned synthetic PPTX through Notes, opens its preview, enters a new
editable native generation, inserts a slide, waits 120 seconds, saves and closes,
then saves and reopens the same document twice. It follows remembered edit mode
on reentry. Acceptance requires each editable generation's own decoded rendering,
edit acknowledgment and save, ordered close/reopen events, revision continuity,
five document-region frames, and the saved four-slide PPTX. Missing receipts,
missing engine, blank content, stale host provenance and absent persistence fail.
System logs, crash reports and video are retained. Existing simulators are preserved.

Local preparation checks: 77 controlled logic tests, 20 host-pin tests and 21
device-bootstrap tests passed; project generation, actionlint and Swift parsing
passed. These do not replace complete App compilation, simulator execution or
physical-device testing. Local-model real-weight search answers remain unqualified.

## 中文状态

本轮 Linux 安装状态、缓存失效与实际启动镜像的双核资格链路已审查；搜索网络边界
和上下文显示已修正源码，尚待完整 App 与设备验证。新 Office 原生宿主已编译，
完整包、4780 个资源与补丁来源已由主线程核验并固定。中文字体用户已确认正常。

PPT 编辑闪退仍缺匹配的系统崩溃栈，不能宣称已修好。首次云端 Xcode 模拟器核心
编译完成后，编辑器配置因子进程的 Python 环境缺少 `lxml` 而失败；留下的是日志，
没有可复用的引擎整包。修复环境与核心产物留存后，安装实际 Floe App，完成预览、编辑、静置 120 秒、保存和同一
文档两次重开测试。受控测试、宿主链接与云模拟器结果分别记录；模拟器通过也不等于
iPad 真机验收。本地模型真实搜索回答仍未通过资格检查。目前没有 Build240 发布标签。
