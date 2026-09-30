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
The recovery now binds phase subprocesses to the prepared Python virtual
environment and checks the actual configure interpreter and pinned imports
before compilation. A completed-core checkpoint is created and uploaded before
editor work; checkpoint retention failure blocks that work. Resume validates
source, archive and file hashes, simulator architecture/platform, Xcode and SDK
version/build, relocates the linker manifest, and runs only editor phases. The
primary also reproduced and corrected a fresh-build ordering regression.
Independent local checks passed: 103 core-pipeline tests, 47 focused tests with
Python 3.12, and 77 full-Floe pipeline tests, plus actionlint. These are
controlled checks, not a real engine run. The full Floe App PPT scenario has
not run; no simulator render or runtime pass is claimed.

Recovery run [36729016248](https://github.com/JiangNanGenius/floe-agent/actions/runs/36729016248)
completed the core in 12,265.5 seconds; it did not remain hung. The next
checkpoint step failed because its optional tool runner was passed as `None`.
The primary's earlier injected-runner tests missed the actual CLI default path.
The retained artifact again contains only logs; there is no reusable compiled
core and the PPT scenario has not started. The primary reproduced that CLI
failure and fixed optional-runner resolution for both creation and restore.
The next candidate checks actual checkpoint CLIs and platform tools on a tiny
synthetic arm64 simulator archive before building Office, and rejects an
actual iPhoneOS archive. Local Xcode 27 tool checks passed; these are not an
Office build or PPT test. The workflow now retains an explicitly unverified
recovery archive if normal checkpoint retention fails; it cannot unlock editor
or runtime acceptance. Phase output reports measured log growth and process-tree
CPU once a minute, with unavailable observations left unknown. 110 controlled
pipeline tests passed; the real cloud recovery remains a separate gate.

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
没有可复用的引擎整包。子进程环境绑定、编译前检查和核心检查点留存已修正；
检查点上传失败时不会继续编辑器构建，恢复时核验源码、摘要、模拟平台和工具链，
跳过核心重编译。主线程另复现并修正完整构建入口的检查顺序；独立通过 103 项核心
流水线测试、Python 3.12 下 47 项定向测试和 77 项完整 Floe 流程测试。这些是受控
检查，尚待云端实际运行。真实引擎就绪后，安装实际 Floe App，完成预览、编辑、
静置 120 秒、保存和同一文档两次重开测试。受控测试、宿主链接与云模拟器结果分别记录；模拟器通过也不等于
iPad 真机验收。本地模型真实搜索回答仍未通过资格检查。目前没有 Build240 发布标签。

恢复运行 36729016248 的核心实际在 12,265.5 秒后成功完成，未永久卡死；随后保存
脚本把空的可选工具调用函数当函数执行，检查点失败。此前注入工具函数的测试遗漏了
实际 CLI 默认路径，是主线程审查遗漏。附件再次仅有日志，没有可复用核心，PPT 场景
仍未执行。主线程复现后已修正创建和恢复的默认工具路径，并新增昂贵编译前的实际
CLI 和平台工具检查：用微型 arm64 模拟器对象验证保存/恢复，并确认拒绝真机平台
对象。本地 Xcode 27 检查已通过，但不是 Office 或 PPT 验收。检查点留存失败时新增
明确未核验的隔离备份，不允许借此继续编辑器或运行验收；编译每分钟输出日志增长、
进程树 CPU 与磁盘观测，无法观测的字段保持未知。110 项受控流水线检查通过，
新的真实云端恢复仍待运行。

Run 36757739330 completed the real core in 10,786.5 seconds, then failed during
checkpoint collection on a dangling optional dependency link. The emergency
quarantine artifact retained the compiled source and outputs. It is unverified
recovery data, not a ready engine or PPT acceptance. The primary reproduced the
collection failure and limited the fix to missing non-header links in optional
dependency discovery, with each omission recorded in the hashed manifest.
Required headers, resources, configure inputs, linker inputs and outside-root
links still fail. A separate manually dispatched conversion binds the reviewed
run, workflow source, archive hash/size and actual SDK/Xcode identity; it rejects
unsafe tar members and then runs the normal checkpoint gates. It runs neither
the core nor the editor build. 122 controlled pipeline checks and actionlint
passed. A tiny actual arm64 simulator archive passed conversion/default tools
and normal restore on local Xcode 27; the synthetic disk budget was substituted
because the local reserve check correctly blocked the first attempt. This is
tool-path evidence only. The cloud conversion and actual Floe PPT scenario are
still pending; no Build240 release has been published.

运行 36757739330 的核心实际在 10,786.5 秒后完成，随后检查点扫描缺失的可选
依赖链接失败。这次隔离备份成功保住了编译源码和产物，但仍是未核验恢复数据，
不能作为就绪引擎或 PPT 验收。主线程已复现扫描错误，仅允许在可选依赖发现时
跳过缺失的非头文件链接，并把每个遗漏写入摘要绑定的清单；必需头文件、资源、
配置输入、链接输入和越界链接仍失败。独立人工触发的转换绑定已审查运行、工作流
源码、整包摘要/大小及实际 SDK/Xcode，拒绝不安全归档，再执行正常检查点门槛；
不重编核心，也不执行编辑器。122 项受控流水线检查与 actionlint 已通过。微型真实
arm64 模拟器对象已验证转换、默认工具及正常恢复；首次本地检查被磁盘预留正确
阻止，后续仅在合成测试中替代磁盘预算，生产限制未放宽。这仅是工具路径证据。
云端转换及实际 Floe PPT 场景尚待完成，目前没有 Build240 发布。

Conversion run 36785511666 verified the raw archive hash, source, toolchain and
safe extraction, then correctly rejected a missing ZXing `libzint/aztec.h` link.
Primary checked the pinned upstream unpack/static-library recipes and the actual
dependency tarball against its pinned SHA256. The recipes explicitly document
unused experimental-submodule links; the library builds no libzint objects.
The correction permits only the 36 reviewed header link/target mappings when
both recipe hashes match, recording each omission and its source evidence in
the checkpoint manifest. Unknown headers, changed recipes and required inputs
still fail. 127 controlled checks and the actual dependency-link audit passed.
The original cloud failure is retained; recovery reuses the same raw core and
does not compile the core again. PPT execution remains pending.

转换运行 36785511666 已核验备份摘要、源码、工具链及安全解包，随后正确拒绝缺失
的 ZXing `libzint/aztec.h` 链接。主线程核对固定版本的两份上游构建文件，并按固定
摘要验证实际依赖原包：上游明确说明这些实验子模块链接不用于构建，静态库也不
编译 libzint 对象。修正仅允许两份构建文件摘要匹配时，跳过逐项审查的 36 个
头文件链接及对应目标，并把遗漏和来源证据写入检查点清单。未知头文件、构建
文件变化和必需输入仍失败。127 项受控检查及实际依赖链接审计已通过。原失败
保留，恢复继续复用同一核心备份，不重新编译核心；PPT 场景仍待执行。

Conversion 36787219632 succeeded at workflow source
`2fc7ea1e9140cbbddaf0d9e3bd54134aca8d411a` and preserved a normal core checkpoint.
Its tar is 498,083,817 bytes, SHA256
`01d5257441f06da77fbb4675f917557d15b1bfea2e28a7da90f1c35d1692eb09`.
Primary checked the engine pin and deployment patch, SDK 27.0 build 24A430,
Xcode 27.0 build 27A266a, 369 linker entries, and all 11 archive samples showing
arm64/IOSSIMULATOR. The hashed manifest contains 59,317 entries and audits 60
unused ZXing links, including the exact 36 reviewed headers. The artifact is a
completed core only: editor construction and actual Floe PPT execution remain
pending. Resume must validate the whole tar and per-file hashes before running
editor phases; the core is reused.

转换 36787219632 已成功，源码为
`2fc7ea1e9140cbbddaf0d9e3bd54134aca8d411a`，正常核心检查点已云端保留。
内层包大小 498,083,817 字节，SHA256 为
`01d5257441f06da77fbb4675f917557d15b1bfea2e28a7da90f1c35d1692eb09`。
主线程核对固定引擎与部署补丁、SDK 27.0/24A430、Xcode 27.0/27A266a、369 个
链接输入及 11 份实际归档样本的 arm64/IOSSIMULATOR 平台证明。摘要绑定的清单
包含 59,317 项，审计 60 个未使用的 ZXing 链接，其中头文件恰为已审查的 36 项。
这仅是完成核心的检查点，编辑器构建与实际 Floe PPT 场景仍待执行；恢复时必须
再验证整包与逐文件摘要，随后仅运行编辑器阶段，复用核心。


### Editor staging portability (2026-09-30)

Resume 36789644676 restored the verified core and skipped core compilation.
Editor autogen, configure and browser build succeeded, but staging rejected an
external `source/compile` symlink created by upstream Automake. Its artifact
contains failure evidence only, not a reusable staged engine. The candidate
reinstalls Libtool helpers/macros and Automake auxiliary files using their
`--copy` options before configure, without changing packager containment rules.
A real local autotools fixture reproduced the original failure, then packaged
portable helper copies and still rejected an unrelated external link. All 128
focused pipeline checks and actionlint passed. This is local tooling evidence,
not completed cloud staging, full-App compilation or PPT runtime acceptance.
The next editor-only resume reuses checkpoint 36787219632; no core rebuild.

续编 36789644676 已恢复核验过的核心并跳过核心编译。编辑器生成、配置和浏览器
构建通过，打包阶段拒绝上游 Automake 生成的外部 `source/compile` 链接；该次
产物只有失败证据，不能当可复用引擎。候选修复在配置前让 Libtool 和 Automake
以 `--copy` 安装辅助文件及宏，保持打包器的路径边界检查。主线程使用实际本地
构建工具复现原失败，验证复制后可打包、无关外部链接仍被拒绝；128 项定向检查
及 actionlint 通过。这是本地工具路径证据，不是云端打包、完整 App 或 PPT
运行验收。后续仅续编编辑器，继续复用 36787219632 核心检查点。


### Pinned generated asset aliases (2026-09-30)

Run 36790727108 passed restored-core validation and the portable helper phases,
then completed the editor build. Staging stopped at the generated QuickLook
asset alias. The pinned configure recipe creates exactly two Contents.json
aliases using source-root-relative targets instead of alias-directory-relative
ones. Candidate staging now validates the exact recipe and target SHA256,
normalizes only these two aliases, and records their old/new targets and hashes
inside qualification/provenance. Missing, modified or unexpected aliases,
symlinked parents and unrelated outside dependencies still fail. The actual
pinned recipe/asset bytes passed the production normalizer locally; 138 focused
checks cover packaging, relocation and rejection cases. The initial local
Python 3.9 test API failure was retained and the synthetic extraction test now
validates tar members before using the supported API. No engine binary changed;
cloud staging and actual Floe PPT execution remain unverified.

36790727108 已通过核心恢复、辅助文件复制和编辑器构建，打包在 QuickLook
生成图标链接处停止。固定上游配置脚本生成的两个 Contents.json 链接误用源码
根目录相对路径；候选打包步骤核验配置脚本与目标摘要，只规范这两个确切链接，
在资格和来源记录中保留原目标、新目标及摘要。缺失、变更、意外链接、父目录
链接与无关外部依赖仍拒绝。主线程已用实际固定上游文件验证生产规范函数；
138 项定向检查覆盖打包、重定位和拒绝情况。本地 Python 3.9 测试接口失败
保留，合成包测试先验证成员，再使用兼容接口。引擎二进制未变，云端打包与
实际 Floe PPT 场景仍未验收。
