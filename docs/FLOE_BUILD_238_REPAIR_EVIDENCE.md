# Build 238 repair evidence / 修复证据

Status (2026-09-30): full App build, signed upload, GitHub prerelease and Feather publication completed. Apple processing and local artifact retention are being verified. 完整 App 构建、签名上传、GitHub 预发布及 Feather 已完成；Apple 处理与本地产物留存正在核验。

## Linux

The status policy now distinguishes a current runner, an explicitly outdated runner, and a manifest that does not declare a runner version. An absent field alone does not prove that a freshly downloaded image is outdated. The runtime protocol handshake still applies.

状态判断区分运行器已更新、明确过旧及清单未声明版本；缺少字段不再单独触发“过旧”。启动协议校验仍保留。

Delta capture uses bounded reusable POSIX I/O buffers and rejects short reads. Only typed transient failures receive bounded retries. The environment repair action preserves quarantined data and uses the existing verified restore path under the same execution lease for user and model entry points.

Delta 保存使用有界复用缓冲区并检查短读，只对明确的暂时性错误有限重试。用户及模型修复入口共用执行租约和已有校验恢复流程，保留隔离数据。

Verification: 440 execution-module XCTest cases passed. A separately compiled production status-policy check passed six assertions, including the published SMP manifest. These are module/policy checks, not iPad startup or full-App acceptance.

验证：440 项执行模块 XCTest 通过；主线程单独编译实际状态策略并验证六项断言，包含已发布 SMP 清单。这不等于 iPad 启动或完整 App 验收。

## Office

Native forwarding now checks negative socket lengths and reads, handles terminal poll events, retires owned descriptors, and prevents duplicate forwarders. Fonts are unchanged; the user reported that Chinese glyphs are now correct.

原生转发检查负长度和读取错误，处理连接终止事件，清理持有的描述符并防止重复启动转发线程。字体保持不变，用户已反馈中文显示恢复。

The primary reviewed the patch and corrected prepared-source hash ordering and artifact provenance checks. The native socket regression harness passed 20 rows; source-copy verification passed eight tests and pin validation passed thirteen tests. These harnesses use controlled engine/JavaScript endpoints and do not open a real PPT on iPad.

主线程审查补丁并修正准备源码的摘要校验顺序和产物来源校验。原生套接字回归矩阵通过 20 项、源码复制校验通过 8 项、产物固定校验通过 13 项。这些测试使用受控端点，不代表真实 iPad PPT 编辑通过。

[Native host build 36669967005](https://github.com/JiangNanGenius/floe-agent/actions/runs/36669967005) compiled and linked source `8adb96ad318fe64e665e310177b83886a5f14043`. [Artifact verification 36670848398](https://github.com/JiangNanGenius/floe-agent/actions/runs/36670848398) checked all 4,780 resource files. Archive SHA-256: `718d49a91bc4605f4f9a50d71daa92bf15bdea5d4fd8298830c3fdc20d5cf501`.

The reported PPT edit crash still lacks a matching system crash stack. This patch fixes demonstrated forwarding defects; it does not establish the cause of every reported termination. PPT editing, save/reopen and the actual device result remain unverified.

PPT 编辑闪退仍缺对应系统崩溃栈。补丁修复了已证实的转发缺陷，尚不能断言它解释了所有闪退；PPT 编辑、保存重开和真机效果仍待验收。

## Delivery and remaining checks / 交付与待核验

Immutable source: `b0467f8350b09441c78d8a381d59620fec5deb3b`, tag `v1.7.0-beta.97`, build 238. [Release workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/36672864766) passed; [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.97) and Feather workflow 36676089499 completed. The unsigned IPA is 739,902,215 bytes. Local artifact downloads remain in progress.

不可变源码及标签如上。完整 App 编译、签名上传、GitHub 预发布及 Feather 已完成；本地备份尚未完成，不能写成已保留。

Apple discovery at 2026-09-30 06:03 UTC reported build 238 as PROCESSING, without a build ID or errors/warnings. VALID, expiry and private Floe QA availability remain to be verified; installability is not yet confirmed.

Apple 当前记录为 PROCESSING，无错误或警告，尚需核实 VALID、未过期及私有 Floe QA 可用性；不能据此声称可安装。

Gitee remains a source/Release synchronization target only. It will not be included as an App acceleration or fallback source in subsequent changes. The already frozen build 238 is unchanged.

Gitee 仅保留源码与 Release 同步用途；后续代码移除其内置加速及后备下载角色。已冻结的 Build238 不作替换。

## Local model / 本地模型

41 controlled harness checks passed. Both tracked test files typechecked; complete Swift Testing suites were not executed locally. Swift 6 object compilation covered the runtime and a reduced local-model module with an injected engine shim.

41 项受控检查及新增测试文件类型检查通过；完整测试套件未在本地运行。Swift 6 对象编译覆盖运行时及注入引擎替身的精简模型模块。

Real-weight run 36672679602: two file-tool turns and receipts passed on macOS, but the first search answer fabricated content instead of using its receipt. The second search was not reached. Overall qualification failed; this is not iPad evidence.

真实权重测试两轮文件工具及回执通过，但首次搜索回答编造内容，第二次搜索未执行，整体资格检查失败。平台为 macOS，不是 iPad 验收。
