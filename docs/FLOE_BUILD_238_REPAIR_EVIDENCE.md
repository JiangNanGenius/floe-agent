# Build 238 repair evidence / 修复证据

Status: candidate work, not yet an App release. 当前为候选修复，尚未交付新版 App。

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

## Pending / 未完成

- The dedicated Gitee repository is public and contains the MPL-2.0 license and component notice. Image upload and anonymous download verification are still in progress. Gitee 专用仓库已公开并包含许可证及组件声明，镜像上传和匿名下载仍在验证。
- Full-App compilation, IPA preservation, TestFlight availability and release delivery have not started for this candidate. 此候选的完整 App 编译、IPA 保留、TestFlight 可用性及发布尚未开始。

Model update: 41 controlled harness checks passed. Both tracked test files typechecked; the complete Swift Testing suites were not executed locally. Swift 6 object compilation covered the runtime and a reduced local-model module with an injected engine shim. Real MLX engine compilation remains a cloud check. Real-weight diagnostic run 36672679602 is pending, not a pass.

模型更新：41 项受控检查通过，新增测试文件类型检查通过。完整测试套件未在本地运行，真实权重诊断还在进行。
