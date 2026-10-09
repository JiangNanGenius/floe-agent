# Build 265 分发补齐 / Distribution catch-up

核验日期 / Verified: 2026-10-09。GitHub 发布时间 / Published: 2026-10-09T02:45:21Z。

本次补齐 GitHub 预发布与 Feather/AltStore 安装源，复用已留存的设备产物，没有重新编译 App、签名上传或变更测试组。This synchronizes GitHub and the source feed using the retained device artifact; no App rebuild, new TestFlight upload or test-group change.

| 项目 / Item | 已核验事实 / Verified fact |
| --- | --- |
| 公开预发布 / Public prerelease | [Floe Agent 1.7.24 (265)](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.24) |
| 不可变源码 / Immutable source | `v1.7.24` · `246d6c038f0a3f7ec7d7d9f7e19d074f13601bec` |
| IPA | `Floe-Agent-1.7.24-build265-unsigned.ipa` · 742263554 bytes |
| SHA-256 | `976e34ad5801f30fd5805c4f0904c06e94e64ad3489e265d1c0e0d0fa7ffaccb` |
| 包身份 / Bundle | `org.floeagent.ios` · 1.7.24 (265) · iOS/iPadOS 26+ |
| 状态 / Signing | 未签名开发者包，需自行签名 / Unsigned developer IPA; own signing required |
| 安装源 / Feed | [Feather / AltStore source](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json), latest entry 265 |
| Apple 只读核验 / Readback | [37872109678](https://github.com/JiangNanGenius/floe-agent/actions/runs/37872109678): VALID, unexpired, internal IN_BETA_TESTING; external WAITING_FOR_BETA_REVIEW |

## 传输与完整性 / Transport and integrity

大文件上传链路偏慢，本次使用已发布 Build 241 作为传输字典，在云端还原**已核验 Build 265 IPA 的原始字节**。基底、差量和最终 IPA 都固定 SHA-256；本地还原与云端还原均匹配以上目标摘要。基底仅用于减少网络传输，不参与重新编译，也没有把旧版本代码作为新 App 发布。

The published Build 241 package served only as a transport dictionary. A hash-pinned delta restores the exact already-verified Build 265 IPA bytes; base, delta and result hashes are checked. This does not rebuild or modify the App. [Transport-only workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/37875893305). Temporary transport parts are removed before publication.

发布包已检查 ZIP 完整性、版本/包名/UUID、签名材料缺失与 PDFium 绑定；脱敏密钥扫描通过。GitHub 资产 API 返回的 SHA-256 与本地文件一致。发布附带 PROVENANCE、校验文件、测试范围、许可证清单、软件清单和扫描结果。

Checked: ZIP integrity, bundle/version/UUID, no signing materials, PDFium linkage and a redacted secret scan. GitHub asset digests match local files. Provenance, checksums, test scope, license inventory, SBOM and scan results accompany the IPA.

## 验证边界 / Limits

- 原有 App 定向验证的来源和范围保留；本轮不是完整云端 App CI、供应商实际效果或真机验收。
- 外部 publictest1 仍待 Apple 审核；未声明外部测试已可安装。
- 分发工具测试 12 项通过。发现并修正一项既有测试的固定字符串前缀假设，使其识别新增的本地产物保护条件；保留原有恢复限制，没有修改发布工作流的既有安全条件。

Original focused App evidence retains its scope. Full App CI, real-provider behavior and physical-device acceptance are not claimed. External beta approval remains pending. Twelve distribution-tool tests pass after correcting an outdated guard-prefix assertion; release safety predicates remain unchanged.

## Gitee 同步边界 / Gitee synchronization scope

2026-10-09 的自动同步已更新发行记录及 7 份小型校验/说明附件，但仓库附件配额不足，IPA 未完成镜像。[同步记录](https://github.com/JiangNanGenius/floe-agent/actions/runs/37876066497)。Gitee 不作为 App 下载加速或自动回退；完整 IPA 使用已验证的 GitHub 发布地址，Feather/AltStore 源同样指向 GitHub。未删除历史资产以腾出配额。

The October 9 automatic mirror updated release metadata and seven small verification/documentation assets, but the attachment quota prevented the IPA mirror. Use the verified GitHub download; the source feed also points to GitHub. Existing historical assets were preserved.
