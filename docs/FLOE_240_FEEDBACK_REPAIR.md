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


### Verified staging and Floe restore adapter (2026-09-30)

Build-stage 36792170654 succeeded at workflow source
`1e1804ead683b0168f4536521f9725623da31ce6`: the core was restored, both portable
helper phases passed, and editor construction plus simulator staging passed.
The reusable engine tar is 599,783,656 bytes, SHA256
`486f42173ece2d3845ee5a78df23536c98160bee0f7f35cc86e7111e99d98a73`.
Cloud provenance records 72,539 manifest entries, 369 linker inputs, 11 actual
arm64/IOSSIMULATOR archive samples, SDK 27.0/24A430 and Xcode 27.0/27A266a.
Its two normalized asset aliases are audited. The upstream host runtime is a
separate diagnostic; this staging success is not actual Floe PPT acceptance.

Before dispatching the full Floe workflow, primary reproduced an adapter bug:
`restore_staged_engine` passed `provenance` to an API expecting `provenance_path`.
The candidate fixes that keyword. A test calls the real default restore API
and confirms invalid provenance is rejected; a signature-bound mock checks
forwarding. All 79 focused Floe pipeline checks and actionlint pass. Retained
initial failures include that real TypeError and a local `/var` versus
`/private/var` fixture-path assertion corrected to match path resolution.
These checks prove adapter/qualification contracts only, not App or PPT runtime.

36792170654 的构建打包阶段已成功，源码为
`1e1804ead683b0168f4536521f9725623da31ce6`：恢复核心、辅助文件复制、编辑器构建
与模拟器打包均通过。引擎包大小 599,783,656 字节，SHA256 为
`486f42173ece2d3845ee5a78df23536c98160bee0f7f35cc86e7111e99d98a73`。
云端记录 72,539 项清单、369 个链接输入、11 个实际 arm64/IOSSIMULATOR 归档
样本以及 SDK 27.0/24A430、Xcode 27.0/27A266a，两处资源链接规范均有审计。
上游宿主运行仅是独立诊断；打包成功不代表实际 Floe PPT 验收。

启动完整 Floe 前，主线程复现恢复适配器误传 `provenance` 参数；实际接口要求
`provenance_path`，候选已纠正。测试调用真实默认恢复函数确认错误来源被拒绝，
并绑定实际签名核验转发；79 项定向检查和 actionlint 通过。原 TypeError 与
本地 `/var`、`/private/var` 合成路径断言失败均保留，后者按真实路径解析修正。
这只证明适配器和资格合同，不代表 App 或 PPT 已运行。


### Full Floe restore-to-preparation integrity repair (2026-10-01)

The first full Floe workflow 36793506615 restored and verified the staged engine,
then failed before native-framework compilation: restoration rewrote the upstream
linker list, whereas Floe native preparation rechecks the original manifest.
Primary reproduced this exact mismatch using both production functions.
Floe restoration now keeps source inputs immutable; native preparation creates
its separate relocated linker list from the verified ordered inputs. The upstream
Mobile diagnostic retains its existing direct-list rewrite. Whole-package,
per-file, source, toolchain and platform gates remain enforced. Two new regression
checks cover repeated preparation, corrupted original-list hashes, and changed
archive/list rejection. All 140 simulator pipeline checks and 79 full Floe
pipeline checks pass; actionlint passes. These are controlled preparation checks,
not App runtime or PPT acceptance. The separate upstream Mobile runtime also
failed with loss of application connection during document-browser interaction;
its original logs are retained for diagnosis and do not establish the Floe crash cause.

首次完整 Floe 流水线 36793506615 已恢复并核验引擎，但在原生框架编译前失败：
恢复步骤改写了上游链接清单，Floe 准备步骤却按原始清单摘要重新核验。
主线程调用两处真实生产函数复现了同一错误。Floe 恢复现保留源输入不变，
准备步骤从已核验的有序输入生成独立的重定位清单；上游 Mobile 诊断仍沿用
直接改写入口。整包、逐文件、源码、工具链和平台检查均保留。新增回归覆盖
重复准备、原清单摘要损坏及归档/清单修改拒绝，140 项模拟器流水线检查、
79 项完整 Floe 流水线检查与 actionlint 通过。这是受控准备检查，尚非 App
运行或 PPT 验收。独立上游 Mobile 运行也在文档浏览交互中丢失应用连接而失败，
原日志保留继续诊断，不能据此确定 Floe 闪退根因。


### Actual simulator framework build and report-contract repair (2026-10-01)

Full Floe run 36794761818 passed restoration and genuine framework compilation,
linking and Swift module import. Its actual load command records IOSSIMULATOR,
minimum iOS 26.0 and SDK 27.0. Packaging then failed with a missing
`swiftImportTarget` field: the compiler used the simulator target, but the producer
did not record it. Primary reproduced the packager failure using the retained
actual cloud build report. The producer now records the target from the exact
import-probe command; packaging does not guess missing fields. Controlled tests
exercise both platform targets, unsuccessful probes, and the producer-to-package-
verification path. All 81 full Floe pipeline checks, 3 native project checks and
actionlint pass. The workflow also retains the native build/import logs and
complete qualification report on failure. The earlier run retained the report,
not a reusable framework package, so only the short native host build must run
again from the same verified engine. No heavy core rebuild is needed. Actual
Floe App compilation and PPT execution have not yet occurred.

完整 Floe 运行 36794761818 已通过恢复及真实框架编译、链接、Swift 模块导入，
实际加载命令记录 IOSSIMULATOR、最低 iOS 26.0、SDK 27.0。之后打包因缺少
`swiftImportTarget` 字段失败：编译确实用了模拟器目标，但构建器未写入回执。
主线程用保存的实际云构建报告复现错误，现直接从真实导入命令记录目标，
打包器仍拒绝缺失字段。受控测试覆盖两种平台目标、导入失败和生产回执到打包
核验的衔接；81 项完整 Floe 流水线检查、3 项原生工程检查及 actionlint 通过。
流水线同时补充保留原生构建、导入日志及完整资格报告。旧运行只保留了报告，
没有可复用框架包，因此需从同一已核验引擎重跑短时宿主编译，重核心不再构建。
实际 Floe App 编译与 PPT 运行仍未完成。

### Simulator framework retained; unit-test module search repair (2026-10-01)

Full Floe run 36795882429 passed genuine simulator framework compilation, linking,
Swift import, packaging, and App dependency installation. Primary retained its
framework package and independently checked all 4785 files, including all 4780
resources, their hashes, source/overlay provenance, and the actual arm64
IOSSIMULATOR binary (minimum iOS 26.0, SDK 27.0). This does not establish editor
runtime acceptance. The App test build then failed: `FloeAppTests` imports the App
module, whose enabled `FloeOfficeNative` dependency was absent from the test
target's framework search paths. The test target now reads the same qualified
host configuration and uses the appropriate device or simulator framework path.
The test target remains enabled. Actual Xcode 27 build settings confirm both
platform paths; a small object-compilation probe using the retained framework's
real headers reproduces the missing transitive module before adding the path and
passes afterward. An initial probe inadvertently serialized its search path and
did not reproduce the failure; that result is retained separately. These focused
checks are not a complete App build. PPT preview/edit/idle/save/reopen has not
executed, and no physical-device crash fix or Build240 delivery is claimed.

完整 Floe 运行 36795882429 已通过真实模拟器框架编译、链接、Swift 导入、
打包及 App 依赖安装。主线程已本地保留框架包，独立核验全部 4785 个文件，
包括 4780 项资源的逐项摘要、源码与补丁来源，以及实际 arm64 IOSSIMULATOR
二进制（最低 iOS 26.0、SDK 27.0）；这尚非编辑器运行验收。随后 App 测试构建
失败：`FloeAppTests` 导入 App 模块时，测试目标缺少其已启用的
`FloeOfficeNative` 框架路径。现让测试目标读取同一已核验宿主配置，按真机或
模拟器平台选择框架路径，仍保留该测试目标。实际 Xcode 27 构建设置确认两种
平台路径生效；使用已保留框架真实头文件的小型对象编译探针，在缺少路径时
复现传递模块缺失，补充路径后通过。初始探针意外序列化了搜索路径，未复现
失败，该结果另行保留。这些定向检查不等于完整 App 构建。PPT 预览、编辑、
静置、保存及重开尚未实际执行，不能宣称真机闪退已修好或 Build240 已交付。

### First full-App simulator execution and evidence-guided corrections (2026-10-01)

Run 36798851422 compiled the actual App and test bundles, installed them on a
fresh iPad simulator, and imported the fixture through Notes. Its durable trace
records native PPT preview decoding and visible rendering in generation 1;
the failure screenshot shows the two-slide document and the host Edit button.
The test stopped before tapping Edit: the accessibility hierarchy shows that
the virtual header's identifier overwrote Edit, Back and other child identifiers.
The header now declares a containing accessibility element to keep child controls
individually identifiable. Actual runtime verification of that change is pending.
The original preview frame was also captured while still opening; the scenario
now waits for the real preview's enabled, hittable Edit affordance before capturing
that frame, without changing the product's preview-to-edit entry policy.

The actual Xcode attachment manifest adds an occurrence index and UUID to the
suggested attachment name. The resolver now recognizes only that exact suffix
format, preserving path/symlink, ambiguity, missing-frame and receipt gates.
Duplicate receipt exports cannot be hidden by the runner-container fallback.
All 85 pipeline logic tests and Swift syntax checks pass. Reprocessing the actual
failed export finds its receipt and original preview frame, but still rejects
the absent edit/idle/reopen frames; it does not turn the failed run into a pass.
Original logs, screenshots, hierarchy, recording and xcresult remain retained.
This run has not tested editable generation handoff, idle, save or reopen, and
does not reproduce or resolve the user's physical-device editing crash.

运行 36798851422 已编译实际 App 与测试包，在新建 iPad 模拟器安装，并通过
手记导入同一 PPT。持久日志记录第一代预览的原生解码及可见渲染，失败截图
也显示两页文档和顶栏“编辑”按钮。测试在点击编辑前停止：实际无障碍树显示
虚拟顶栏的标识覆盖了编辑、返回等子控件标识。现将顶栏声明为包含子控件的
无障碍容器，保留控件独立标识；该改动仍待实际运行验证。原预览截图还拍在
打开过程中，场景现等待真正预览中的编辑按钮可用、可点击后再截图，不改变
产品的预览到编辑入口。

实际 Xcode 附件清单会给建议名称追加序号和 UUID。解析器现只识别该确切
后缀，路径、符号链接、重名、缺图及回执检查继续保留；重名回执不能用测试
容器副本掩盖。85 项流水线逻辑测试和 Swift 语法检查通过。重新解析实际失败
导出后已找到原回执和预览截图，但仍拒绝缺失的编辑、静置、重开截图，不把
失败运行改判成功。原日志、截图、无障碍树、录像和 xcresult 全部保留。
本次尚未验证可编辑代际切换、静置、保存和重开，也不能据此宣称已复现或
解决用户真机的编辑闪退。


## Actual edit-entry exception, 2026-10-01

[Full Floe simulator run 36802940235](https://github.com/JiangNanGenius/floe-agent/actions/runs/36802940235)
compiled the complete App and UI tests, rendered the imported Notes PPT preview,
and successfully clicked the host Edit action. The preview close acknowledged
and the second native generation opened. The App then terminated during edit
entry. The original xcresult diagnostics contain the uncaught
`NSInvalidArgumentException`: `Invalid top-level type in JSON write`, with
`armEditSurfaceEvidenceWithCompletion:` and `runEditEntryAndReport` in the
native stack. The failure screenshot shows the simulator home screen. No edit,
idle, save or reopen acceptance is claimed; all failed gates remain retained.

The primary reproduced the exception by compiling the extracted production
function against real Foundation. Its JSON root is a string token; the write
now explicitly allows JSON fragments. A compiled production-function regression
checks token round trips, escaping, Chinese text, empty strings and nil. Nine
focused native-entry tests and 85 pipeline checks passed, along with Swift
parsing and actionlint. The UI test now waits for the mounted editor to become
ready and detects a foreground exit rather than treating mounting as edit
acknowledgement. Cloud log collection includes App process messages.
The corrected full-App scenario and a refreshed device-host pin are still
required. This is a matched simulator exception, not a matched physical-device
crash stack or a Build240 delivery.

## 真实进入编辑异常，2026-10-01

完整 Floe 云模拟器运行 36802940235 已编译 App 和交互测试、渲染手记中导入的
PPT 预览并点击真实“编辑”。预览关闭已确认，第二代原生编辑实例已打开，随后 App
在进入编辑时退出。原始 xcresult 诊断记录了未捕获的 NSInvalidArgumentException：
JSON 写入的顶层对象类型无效；原生栈指向编辑绘制证据脚本生成和编辑进入函数。
失败截图为模拟器桌面。编辑、静置、保存及重开验收均未通过，原始失败完整保留。

主线程提取生产函数，用真实 Foundation 编译复现该异常；字符串根对象现明确使用
JSON fragment 写入选项。新增编译生产函数的回归验证转义、中文、空字符串、nil
及 token 往返。9 项原生进入编辑定向测试、85 项流水线检查、Swift 语法及 actionlint
通过。交互测试等待真实可操作编辑状态，并识别 App 离开前台；云日志包含 App
进程信息。修正版完整 App 场景及新的设备宿主 pin 仍待核验；模拟器匹配异常不能
替代真机崩溃栈或 Build240 交付验收。

## Rebuilt device host retained and pinned, 2026-10-01

Device-host run 36807680175 built the edit-entry JSON fix from source
`f5656f18456f96207e8e12ed4a9d61e57af522e3`. The primary retained the complete
126,572,466-byte inner archive (SHA-256
`f76a9975886f135dce977938680c0c395432d5eaf46e6d925e58c61fcb5268fa`)
and independently verified all 4,785 files, including 4,780 runtime resources,
source hashes and lifecycle-overlay provenance. Actual binary load commands
confirm arm64 iOS, minimum OS 26.0 and SDK 27.0. The device-host pin now records
this artifact. All runtime capability claims remain false.

The previous corrected simulator run 36807569442 stopped before App compilation:
bootstrap correctly rejected the old device pin against the changed host source.
Its original failure remains retained. The next full-App scenario uses the new
pin and the same verified simulator engine; no heavy engine rebuild is required.
PPT editing, idle, saving, reopening and physical-device acceptance remain pending.

## 新设备宿主完整留存并固定，2026-10-01

设备宿主运行 36807680175 已从 f5656f18 源码构建进入编辑的 JSON 异常修正。
主线程完整保留 126,572,466 字节内层 ZIP，核验全部 4,785 文件、其中 4,780
运行资源的摘要，以及源码和生命周期补丁来源。实际二进制为 arm64 iOS，
最低系统 26.0、SDK 27.0；组件锁定版本已更新，运行能力声明仍全部为未通过。

前一修正版模拟器运行 36807569442 在 App 编译前被旧设备 pin 的源码校验
正确阻止，原始失败保留。下一完整 App 场景使用新 pin 和已核验的同一模拟器
引擎，不重编核心。PPT 编辑、静置、保存、重开及真机验收仍待实际验证。

## Corrected App reaches editable rendering, 2026-10-01

Full-App run 36812220870 compiled and executed the corrected App. Its retained
trace records the real preview close acknowledgement, a new editable generation,
edit permission, edit acknowledgement, and visible rendering after the edit
surface was armed (82 changed samples, Impress layout). The failure screenshot
shows the App displaying the two-slide document in its mobile editor. The old
JSON exception is absent from this run's exported App stdout. These observations
cover this execution only; they do not establish physical-device crash acceptance.

The scenario stopped while searching for an Insert Slide control. The pinned
runtime bundle defines the mobile bottom-toolbar insertion control as
`.uno:InsertPage`, labelled `New Page`; the test's label list omitted it. The test
now recognizes that existing UI label, checks that the control is actionable,
and retains an accessibility hierarchy at insertion for subsequent diagnosis.
It still requires the actual slide count to advance. No product control, edit
entry, idle deadline, save/reopen chain or persistence/render gate was changed.
The original failed run, complete xcresult, screenshots and diagnostics remain
retained. Insertion, 120-second idle, saving and reopening remain unverified.

## 修正版 App 已进入可编辑渲染，2026-10-01

完整 App 运行 36812220870 已编译并实际运行修正版。完整留存日志记录真实
预览关闭确认、新编辑代际、编辑权限和确认，以及绘制监测启用后的可见渲染
（82 个变化采样点、Impress 布局）。失败截图仍显示 App 中的两页 PPT 编辑器；
本次导出的 App 输出没有旧 JSON 异常。这些证据只覆盖本次模拟器运行，
不能替代用户真机闪退验收。

场景在查找插入幻灯片控件时停止。固定运行包中，移动底栏的插入控件对应
.uno:InsertPage，标签为 New Page，原测试查找列表漏了该标签。现补齐现有
控件标签、验证控件可用且可点击，并留存插入时的无障碍树；仍要求真实页数
增加。产品控件、编辑入口、静置时长、保存重开及渲染和落盘门槛均未改变。
原失败完整 xcresult、截图和诊断保留；插入、静置 120 秒、保存和重开仍待验证。

## Actual insertion observed; scenario harness corrected, 2026-10-01

[Full-App run 36816042307](https://github.com/JiangNanGenius/floe-agent/actions/runs/36816042307)
compiled and clicked the real `New Page` button. The complete retained xcresult
accessibility tree contains `页面预览 1`, `页面预览 2` (selected) and
`页面预览 3`; its recording shows a newly inserted blank slide between the two
original slides. This demonstrates insertion in this simulator execution.
The test missed the Chinese thumbnail label, then aborted while enumerating a
changing button query using an earlier count. The original run remains failed:
it produced no completed scenario receipt, idle/save/reopen chain or four-slide
persistence acceptance. Its App stdout contains neither the earlier JSON
exception nor an uncaught-exception entry; that absence covers only this run.

The test now recognizes the exact Chinese thumbnail label and removes the
racy optional diagnostic enumeration, while retaining the pre-tap hierarchy
and actual page-count assertion. After insertion and on the final reopen, it
selects the original content slide through the real thumbnail UI and requires
its selected state before capturing content frames. This preserves the strict
document-region rendering check when the inserted slide is intentionally
blank. The real insertion, 120-second idle, save/close, two reopens, native
generation, receipt and four-slide persisted-file gates remain unchanged.
Swift syntax validation and 85 pipeline logic tests pass; the corrected
full-App scenario and physical-device acceptance remain pending.

## 已观察到真实插页，修正场景测试，2026-10-01

完整 App 运行 36816042307 已编译并点击真实 New Page 按钮。完整留存的
xcresult 无障碍树包含“页面预览 1、2、3”，第二页已选中；录像显示两张
原有幻灯片之间新增了一张空白页。这证明本次模拟器运行已实际插页。测试
漏识别中文缩略图标签，随后用旧数量枚举动态按钮列表时中止。原运行仍为
失败：没有完整场景回执、静置与保存重开链，也没有四页文档落盘验收。
本次 App 输出没有旧 JSON 异常或未捕获异常记录，只能说明本次运行。

测试现识别精确中文缩略图标签，移除不稳定的可选诊断枚举，保留点击前
无障碍树和真实页数断言。插入后及最终重开时，通过真实缩略图界面选回
原有内容页，并等待已选中状态再拍内容帧，避免把刻意插入的空白页当作
渲染失败。真实插入、静置 120 秒、保存关闭、两次重开、原生代际、回执
及四页落盘门槛均保留。Swift 语法检查与 85 项流水线逻辑测试通过；修正版
完整 App 场景及用户真机验收仍待验证。

## Edit, idle and saved reopens observed; trace qualification still failed, 2026-10-01

[Full-App run 36821043378](https://github.com/JiangNanGenius/floe-agent/actions/runs/36821043378)
compiled and passed the actual Notes PPT interaction test. Its complete retained
xcresult contains all 17 successful scenario phases, including 120.27 seconds
of idle, saving and two reopens. All five document-region frame checks and the
four-slide persisted-resource check passed. The primary independently exported
the xcresult attachments again, resolved the GUID manifest without a runner
fallback, and matched the receipt and all five frames byte-for-byte to the cloud
copies. The final frame displays the original content and four thumbnails.

The run remains **failed** at the durable trace gate. All three editable
generation-2 windows contain editable confirmation, their own real paint,
save, commit and close, with Notes revisions continuing 1 → 2 → 3 → 4. None
contains `edit.entry`: the actual App permission branch returns when the host
has already entered edit mode, without recording that observed entry. The
unchanged verifier therefore refuses the preview-to-edit chain.

The App now records that entry only when backing permission is editable and
the probe explicitly reports an active edit UI, labelled
`branch=already-editable-probe`. It does not invoke editing again, change
permissions or emit the breadcrumb for an unknown UI mode. Object compilation
and execution of the exact extracted production branch reproduce the missing
event before the change and verify the corrected true/false/unknown cases.
Swift syntax and 85 pipeline tests pass. The trace verifier and all rendering,
generation, lifecycle, revision and persistence gates remain unchanged; the
original failure is retained. A fresh full-App run must validate the new
producer. This is cloud-simulator evidence, not Build240 delivery or physical
iPad crash acceptance.

## 已完成编辑、静置和保存重开，日志资格仍失败，2026-10-01

完整 App 运行 36821043378 已编译并通过真实手记 PPT 交互测试。完整留存
xcresult 包含全部 17 个成功阶段，包括静置 120.27 秒、保存和两次重开；
五张文档区域截图及四页文件落盘检查均通过。主线程再次导出原始附件，按
GUID 清单解析回执和截图，未使用 runner 回退；全部内容与云端副本逐字节
一致。最终截图可见原有内容和四页缩略图。

原运行仍因持久日志门槛而失败。三次第二代编辑实例都记录可编辑确认、
自身实际绘制、保存、提交和关闭，手记版本链连续为 1 → 2 → 3 → 4；
但均缺少 edit.entry。实际 App 在宿主已进入编辑模式时直接接受探针结果，
漏记了这个已观察到的进入状态，因此未修改的校验器拒绝预览到编辑链路。

现只在底层权限可编辑且探针明确确认编辑界面已启用时补记该状态，标明
already-editable-probe 分支；不会再次触发编辑、修改权限，也不会为未知
界面状态记录已验证进入。提取原版和修正版生产分支进行对象编译及执行，
复现原版漏记，并验证修正版的真、假、未知三种探针结果；Swift 语法和
85 项流水线测试通过。日志校验器及渲染、代际、生命周期、版本连续性和
落盘门槛均未改变，原始失败保留，新的完整 App 运行仍须验证补记结果。
本节是云模拟器证据，不代表 Build240 已交付或用户真机闪退验收通过。


## Late render observation and truthful exit checks, 2026-10-01

[Full-App run 36825093835](https://github.com/JiangNanGenius/floe-agent/actions/runs/36825093835)
compiled, but its complete retained xcresult shows actual render deadlines,
not just a card-selection failure. The first preview timed out without decoded
tiles. Its editable generation later painted and committed Notes revision 2.
On the first reopen, the editable generation reached its 25-second deadline
while guarded edit entry was still running. The original trace then records
`save.refused permitsSave=false`; the final screenshot remains inside the
four-slide editor with the unverified-render warning. No second commit or
completed second reopen was accepted. The original run stays **failed**.

The native probe previously stopped permanently at the notice deadline, so a
later actual paint could never repair the App's render gate. The candidate
keeps the original notice deadline and observes only that same generation for
at most 60 additional seconds. A real render and the entry's own acknowledgement
remain required; blank skeletons, silent evaluations and elapsed time cannot
permit saving. Cancellation stops observation, and the final recovery bound
settles a still-pending entry. Original failure events remain in the trace and
continue to fail qualification; the verifier has not changed.

The App exposes its existing document-action readiness to accessibility. The
UI test requires that readiness before preview/edit frames and now verifies
that both native surfaces and the editor back action disappeared, with the
Notes library actually hittable, before claiming save-and-close. An existing
Notes button behind the editor can no longer satisfy the exit check.

The original extracted native probe reproduces the lost late-paint assertion.
Object compilation and execution of the shipped probe and failure callbacks
pass nine Foundation/dispatch lifecycle cases, including delayed entry
acknowledgement, missing paint, missing JS callbacks and cancellation. The
recovery timer alone is scaled for this component harness. Focused native,
render-readiness and pipeline checks pass. A rebuilt and fully verified device
host pin, a fresh full-App simulator scenario and physical iPad acceptance
remain pending. This is not Build240 delivery or a claim that all PPT crashes
are resolved.

## 迟到渲染观察与真实退出检查，2026-10-01

完整 App 运行 36825093835 已编译，但完整 xcresult 显示实际渲染超时，
不能只归因于卡片定位。首次预览未解码文档瓦片即超时；随后编辑实例实际
绘制并提交手记版本 2。第一次重开时，编辑实例在原生进入编辑尚未结束时
达到 25 秒期限。原日志随后记录保存被拒绝；最终截图仍在四页编辑器内，
显示未验证渲染警告。没有第二次提交或完整第二次重开验收，原运行仍失败。

原生探针原来在提示超时后永久停止，因此迟到的真实绘制无法修复 App 的
渲染门槛。候选保留原提示期限，仅对同一代际继续观察最多 60 秒；仍必须
观察真实渲染和进入编辑的确认，空白骨架、无回调或时间流逝均不能允许保存。
关闭会取消观察，恢复观察最终到期则结束尚未完成的进入等待。原始失败事件
仍保留并阻止资格通过，校验器没有放宽。

App 将已有文档操作就绪状态提供给无障碍接口，测试在截图及编辑前要求
该状态。保存退出须确认原生预览、编辑器及返回按钮真正消失，且手记列表
实际可点击；编辑器背后仍存在的“新建手记”不再被误判为退出成功。

提取原版探针已实际复现迟到绘制被丢弃；修正版探针及失败回调经对象编译
和执行通过九项 Foundation/dispatch 生命周期案例，包括迟到编辑确认、
未绘制、无 JS 回调及取消。组件测试只缩短恢复计时，不是实际引擎验收。
定向原生、渲染规则和流水线检查通过，设备宿主整包重新核验固定、完整
App 云模拟器场景及用户真机验收仍待完成；不代表 Build240 已交付或所有
PPT 闪退均已解决。

## Font transport recovery, 2026-10-01

Device-host run 36833209832 failed before native compilation in both attempts:
the first failed fetching Source Han Sans TC, while the second fetched TC but
failed fetching SC with curl 56 / HTTP 500. The font manifest and versions
remain unchanged. The downloader now retries transport errors as well as
HTTP errors, with a bounded retry window and per-transfer timeout. Failed
partial files are never promoted to the download cache.

Three focused checks pass, including real curl recovery after a local server
drops its first connection, permanent failure without partial-file promotion,
and existing-cache reuse. The original downloader needed a separate fallback
curl process for the same dropped connection. This is transport evidence,
not a successful cloud host build or PPT acceptance; those remain pending.

## 字体下载传输恢复，2026-10-01

设备宿主运行 36833209832 两次均在原生编译前失败：首次下载思源黑体繁体包
失败，第二次繁体包成功，但简体包出现 curl 56 / HTTP 500。字体清单和版本
未改变。下载器新增传输错误重试，并限制重试窗口及每次传输时间；失败的
临时文件不会被提交为完整下载缓存。

三项定向检查通过，包括真实 curl 从本地服务首次断开连接中恢复、永久
失败不提交临时文件，以及复用已有缓存。同样的断连在原版函数中需要另启
回退 curl 进程。此证据只覆盖传输恢复，云宿主构建及完整 PPT 验收仍待完成。

## Verified bounded-render host, 2026-10-01

Device host run 36835213892 succeeded from source
`91540d6ed4d2b1ef519392fc34f037fe2e33e354`. The complete archive is saved
locally: 126576751 bytes, SHA-256
`ba70c370ce6e744116f578c5393d606741713f271054e831a3d0803dc05dad01`.
Primary verification matched the independently downloaded manifest and checked
all 4785 files, including 4780 resources, source hashes and overlay provenance.
The actual binary is arm64 IOS, minimum OS 26.0, SDK 27.0. The device host pin
now selects this verified archive; runtime capability flags remain false.
Full-App cloud simulator PPT qualification and physical iPad acceptance remain
pending. No Build240 release or tag is created by this host qualification.

## 有界渲染宿主整包核验，2026-10-01

设备宿主运行 36835213892 从源码
`91540d6ed4d2b1ef519392fc34f037fe2e33e354` 构建成功。完整压缩包已本地
留存，126576751 字节，SHA-256 为
`ba70c370ce6e744116f578c5393d606741713f271054e831a3d0803dc05dad01`。
主线程核对独立下载的清单，并验证全部 4785 文件，其中包含 4780 项资源、
源码摘要及补丁来源。实际二进制为 arm64 IOS，最低系统 26.0，SDK 27.0。
设备宿主固定项更新为此已核验整包，运行能力标志仍为 false。完整 App 云
模拟器 PPT 验收及用户物理 iPad 验收仍待完成；此宿主资格不创建 Build240
标签或发布。

## Full-App PPT acceptance, run 36843561563

Source `4ff2eef7a66a84a59b5c33ff574c27f5ed8b0763` passed the genuine Floe App
scenario on a task-owned iPad mini (A17 Pro), iOS 27.0 cloud Simulator. All 17
phases succeeded, including 120.35 seconds idle, two real insertions and two
reopens. All three cloud gates passed. Primary review re-exported the GUID
attachments: the receipt and all five frames byte-match cloud evidence, with
no runner fallback. The native trace replay and real Notes-resource replay
passed locally; three own generation-2 editable sessions committed revisions
2, 3 and 4. Four-slide persisted PPTX files and original marker content were
verified. Actual preview and final four-slide editor frames were viewed.

Optional duplicate local pixel computation was stopped after more than ten
minutes; no local pixel PASS is claimed. The unchanged cloud gate operated on
the same byte-identical frames. An initial persistence replay included four
container metadata files and correctly failed; that output remains. Replaying
the byte-identical actual Notes resources passed without modifying the gate.
Original cloud failures remain failures. This simulator acceptance permits
preparing Build240 internal delivery, but is not physical iPad acceptance or
proof that every user PPT is fixed. The qualification App was versioned 239;
the delivery candidate changes build metadata separately.

## 完整 App PPT 云验收，运行 36843561563

源码 `4ff2eef7a66a84a59b5c33ff574c27f5ed8b0763` 在本任务所属的云端
iPad mini (A17 Pro)、iOS 27.0 模拟器运行实际 Floe App，17 个阶段全部
通过，包含静置 120.35 秒、两次真实插页及两次重开。云端三项门槛全部通过。
主线程重新导出 GUID 附件，回执及五帧与云端证据逐字节一致，没有 runner
回退；原生事件链及实际手记资源本地复核通过。三个各自代际 2 的编辑实例
提交版本 2、3、4，真实四页 PPTX 和原内容标记均已核对，并亲看预览和最终
四页编辑器截图。

本地重复像素计算超过十分钟后停止，不宣称本地像素检查通过；采用未修改
的云端校验器对同字节五帧的通过结果。首次本地保存文件复核误传含四份
容器元数据的目录，校验器正确拒绝，原错误保留；仅用字节一致的实际手记
资源复核后通过，没有修改门槛。旧云端失败不改写。此模拟器资格允许准备
Build240 内测交付，不等于物理 iPad 或全部用户 PPT 已修好；资格 App 的
版本仍为 239，交付候选另行修改构建元数据。
