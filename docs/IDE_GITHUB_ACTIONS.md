# IDE cloud builds / IDE 云端构建

Current status: build 186 / `v1.7.0-beta.43` completed as a **failed**
qualification run on 2026-09-18 and was **not uploaded**. Build 187 / beta.44 has
only version metadata prepared
(`2438fdddc9a613a94d938c62148f9ca90bc440be`); no `v1.7.0-beta.44` tag, no new
release workflow run and no upload exists. See
[beta.43 final record](RELEASE_1.7.0_BETA_43.md) and
[beta.44 preparation](RELEASE_1.7.0_BETA_44.md).

Release run
[`35306551280`](https://github.com/JiangNanGenius/floe-agent/actions/runs/35306551280)
for build 186: `prepare-release` passed, then the NativeNotes development
component, the SDK 27 build/verify job and the accepted-SDK job ran in parallel
under source `d421fea260523d063270e2d21d623bd011acd9ea`. The focused accepted-SDK
app regression passed **204/204, including all 23 IDE job cases**
(`IDEGitHubActionsTests` executed=23 minimum=23). The overall run failed in the
other gates, so the upload job never ran. The 23 cases are real App-test-host
execution of the production client/engine/store recovery paths; the actual App
relaunch by tapping through the UI flow is still not covered, and no TestFlight
availability is claimed. The IDE client/engine/store feature itself is unchanged
from build 184. Foreground recovery activates from the root scene and does not
require opening the IDE panel; backgrounding pauses local polling while the remote
run continues.

Previous candidate: build 185 / `v1.7.0-beta.42`, source
`42ecc4527fdbeb171dd0aed1d0776375770f1572`. The cloud qualification run
[`35292395886`](https://github.com/JiangNanGenius/floe-agent/actions/runs/35292395886)
finished with UI qualification failures; signing and upload were skipped. Both
SDK App regressions passed 204/204, including all 23 IDE job cases. This page
describes the implemented flow, not a TestFlight availability claim. The build
182 section below records the original live dispatch/recovery; build 184 re-ran
the production client/engine/disk-store CLI against the same existing run
(`35247779223`) with 28 passing checks and zero redispatch, but that is CLI
evidence, not App UI acceptance.

## 使用流程

1. 在 GitHub 设置中连接账户。若要安装 Floe 构建模板，登录时启用“允许配置 GitHub Actions 工作流”；已有凭据不会被自动扩大权限。已登录但缺少该授权时，需要重新登录授权。
2. 从文件管理器进入完整 IDE，打开源码，点击运行，选择 **GitHub Actions 云端构建**。明确选择仓库、基础分支和工作流，查看待上传快照的文件数量与大小。
3. 使用已有工作流，或查看 Floe 模板后点击“安装模板到默认分支”。安装只新增对应工作流；若同路径存在不同内容，导出到工作区供审查，不覆盖已有配置。模板涉及的 GitHub 提交是可见操作。
4. 开始运行后，可关闭面板或退出 App。GitHub 上的任务继续；App 会保存仓库、源码提交、任务标识和运行状态。重新打开并进入前台后，自动回读记录并查询远端，不要求模型发送查询工具或等待指令。
5. 在 IDE 运行面板的“运行记录”中查看状态、刷新、请求取消、读取日志和下载产物。取消申请显示“取消中”，直到 GitHub 确认结果。网络中断时保留原记录，不因未收到提交响应而自动重复构建。

App 在前台对已知未完成任务主动轮询，并随无变化结果退避；进入后台暂停本机查询。iOS 终止或挂起 App 时，不能承诺持续后台联网，也不影响远端 CI。重新进入前台会立即恢复查询。多个 App 窗口共享任务中心，关闭其中一个窗口不会停止另一个活跃窗口的查询。

源码按文件构成快照并创建独立运行分支；排除 Git 元数据、明显的凭据文件、符号链接和生成物。单文件上限 5 MiB，总量 64 MiB，最多 2,000 个文件。自动排除不是全面的秘密扫描；选择公开仓库前应确认项目源码适合公开。账户凭据来自已有安全存储，不写入任务记录。

产物按 GitHub artifact 下载为压缩包，当前上限 64 MiB。下载先校验再提交到工作区，不覆盖同名现有文件；若 GitHub 提供 SHA-256 摘要，必须匹配。未提供摘要时只记录本地校验和，不宣称远端摘要验证通过。产物过期或校验失败会明确报错。Linux/macOS 编译产物用于对应平台，不会被当作 iPad 本机可执行文件安装。

## English workflow

Connect GitHub in Settings. Installing a Floe workflow template requires the
explicit workflow authorization option at sign-in; an existing credential is not
silently upgraded. Open source in the full IDE, choose **GitHub Actions cloud
build**, then select the repository, base branch and workflow and review the
snapshot size. Templates can be reviewed before installation on the default
branch. A different existing workflow at the same path is never overwritten.

The App saves the dispatch intent and remote identity. Closing the panel or App
does not cancel the remote build. Reopening reconciles unfinished records;
foreground polling uses bounded concurrency and backoff. Polling pauses while
the App is backgrounded, and resumes when a scene becomes active. No model loop
is needed. A lost dispatch response remains pending association instead of
triggering a duplicate run. A cancellation request is not a completed cancellation.

The run list provides refresh, cancellation, job logs and artifact download.
Snapshots exclude Git metadata, recognizable credential files, symlinks and
build outputs, with limits of 5 MiB per file, 64 MiB total and 2,000 files.
Artifacts are bounded to 64 MiB, staged and checked before committing without
overwriting an existing file. A GitHub-provided SHA-256 must match; a local-only
checksum is not reported as remotely verified. Credentials are not persisted in
job records. Build artifacts target the cloud runner's Linux/macOS platform,
not an executable installation on iOS.

## Engineering and acceptance

App root scene appearance and foreground changes activate the center; opening the
IDE panel is not required for recovery. Covering the root with a full-screen
editor does not deactivate an otherwise active scene.

The app-owned `GitHubActionsJobCenter` publishes state; the actor
`GitHubActionsJobEngine` owns recovery/polling and injectable transport;
`GitHubActionsJobStore` atomically persists individual records. The service uses
run identifiers, source SHA and dispatch correlation, not branch names alone.
Damaged records remain available for diagnosis and are reported rather than
silently deleted. No remote task is classified as a killed local subprocess at
App launch.

Required checks include foreground recovery, multiple scenes, response loss,
cancel-before-association, retry/backoff, terminal-state preservation during an
artifact refresh, redirect authorization handling, digest mismatch, and an
actual GitHub run continued across App relaunch. The local state-machine and
transport fixtures provide focused evidence; they do not replace full-App UI or
real GitHub account verification. See [candidate release record](RELEASE_1.7.0_BETA_43.md)
for current delivery status.

Observed before the build-180 tag: the production center/engine/store/policy and
17 formal App test cases passed Swift 6 semantic checks targeting iOS 26 against
SDK 27 and existing real dependency modules. Actual-source policy, engine and
HTTP fixture harnesses passed, including digest match/mismatch/missing and a
concurrent stale artifact response after run completion. All 14 generated
workflow templates parsed and passed actionlint; a hostile filename was checked
as one literal shell argument. Full-App execution and live-account recovery are
still pending; no cloud build or TestFlight result is implied by these checks.

### Real transport correction in build 181

A real API check exposed that `URLComponents` dropped the base URL when query
parameters were appended. Build 180 was cancelled before upload. The correction
resolves the absolute URL first; fixtures now reject non-HTTPS relative URLs.
The production client with an ordinary URLSession subsequently read workflows,
runs, jobs and artifacts, followed pagination (100 to 198 runs), and downloaded
a small diagnostic artifact with the GitHub digest matching. No transport shim
was used. [Recorded evidence](qualification/build181-release/github-actions/live-api.json)
is a read-only network check, not App relaunch or UI acceptance.

Build 181 adds two real-disk recovery regressions (19 App engine cases total).
A two-process CLI check writes running/cancelling records through the production
store, then a separate process reconstructs the production engine and verifies
foreground reconciliation, preserved cancellation intent, terminal persistence,
and zero dispatch calls. The remote responses in that check are controlled
fixtures; the separate live API check above covers real network transport.

### Build 182 recovery corrections

The actual client/engine/store dispatched one existing read-only workflow,
exited, then a new process recovered run `35247779223` to success without a
second dispatch. This exposed a list-filter delay for a known run ID and a stale
association error still displayed after success. Build 181 was cancelled before
upload to correct both. Build 182 queries a returned run ID directly and checks
its workflow, commit, ref, event, baseline and creation window; 404 is retried
within a bound. A successful run observation clears obsolete run diagnostics
and persists that change without resetting backoff on every unchanged poll.

Read-only replay of that same run returned the correct identity immediately;
recovery of the original pending record reached success with `lastError=nil`
and no dispatch. The focused repair harness passed 28 assertions. The formal
App engine suite now contains 23 cases, and the service fixture suite 25;
Swift 6 semantic checks pass. This remains production-source CLI evidence,
not rendered App UI or TestFlight acceptance.

### Build 184 response freshness

Foreground recovery and polling explicitly bypass the URLSession response cache
and request remote revalidation. Current Actions sources, the engine/store and
25 service / 23 App engine tests passed mandatory SIL and object emission. This
is compiler evidence, not execution of those tests or full-App acceptance.

A production-source CLI check with the current (184) client, engine and disk
store passed 28 assertions: associating the existing run `35247779223` succeeded
by direct run read in 0.42 s without the list endpoint, and a fresh process
recovered the seeded record to completed/success in 2.01 s, cleared the stale
`lastError` and used no dispatch endpoint (`newDispatches: 0`).
[Redacted evidence](qualification/build184-release/live-recovery.json). This
reuses an immutable existing run; it is not a new dispatch, App relaunch or UI
acceptance.

### Build 185 candidate

Build 184 compiled the App on both SDK lines, but each App regression passed
203/204 tests with the same Lua install/run failure and no upload occurred; its
unsigned device recovery archive is retained
([record](qualification/build184-release/device-recovery.json)). The Actions
feature source is unchanged in build 185. Build 184 actually executed the 25
service fixtures in its Swift module job and all 23 IDE engine cases in its
App test host successfully. Earlier mandatory SIL/object checks provide separate
compiler evidence; those checks alone did not execute the tests.
The only runtime repair in this candidate is the WASI environment contract
(`f908cce1`), which is outside the GitHub Actions feature. Run `35292395886` is
the two-SDK qualification for that candidate: both App regressions passed
204/204, but Office cover/navigation UI failures blocked upload. No App relaunch
UI or TestFlight availability is implied.

### Build 186 result and build 187 preparation

Build 186 executed the accepted-SDK focused regression at 204/204 with all 23
`IDEGitHubActionsTests` cases passing. The run still failed and did not upload
because of the other qualification gates (localization namespacing in the SDK 27
module tests, one strict Excel cover case on the iPad component leg, and the
Office back-control UI identifier on both full-App UI legs;
[final record](RELEASE_1.7.0_BETA_43.md)). The IDE feature source is unchanged in
build 187; the only prepared changes are version metadata and Notes-side source.
No 187 tag, release run, signing or upload exists, and the actual App relaunch by
tapping through the run list remains an open UI-level check rather than something
these 23 host cases prove.
