# 文档核对与官网更新 / Documentation and website refresh

日期 / Date: 2026-10-09。源码基线 / Source baseline: `19db9b20`；App 不可变源码 / Immutable App source: `v1.7.24` / `246d6c03`。

## 本次结果 / Changes

- 为开始时全部 496 份已跟踪 Markdown 建立清单；第三方、历史发布与原始验收记录保留。未跟踪草稿不纳入。Inventoried the 496 Markdown documents tracked at task start; third-party, historical release and raw evidence records remain intact. Untracked drafts excluded.
- 双语手册按场景重组，保留旧网页锚点；现行入口统一引用 CURRENT_STATUS，专题补齐 CAD、媒体、Office、手记与运行环境边界。Manuals reorganized by workflow; legacy website anchors retained and current status centralized.
- 架构核对：project.yml 1.7.24/265；DatabaseManager schema 44；cad.document、document.office.edit、media.project 与现行模块一致。This is documentation/source verification, not fresh physical-device acceptance.
- GitHub/Feather 与 Apple 分别只读核验。Apple 检查 37872109678 确认 VALID、未过期、内部可用，外部仍待审。Release synchronization is recorded separately in CURRENT_STATUS.
- 官网使用真实模拟器录屏画面，合成工作坊资料，无伪造产品界面。Recorded simulator imagery, not physical-device proof.

## 验证范围 / Verification scope

- 官网与 GitHub 使用同一份双语图文手册：各 20 个主章节、相同的 4 张真实界面图与双语图注；官网 HTML 和可下载 Markdown 的源正文及哈希一致。
- 生成器 7 项测试通过，涵盖链接转换、特殊字符转义、重复标题、元数据日期、旧锚点、图片复制和正文/哈希一致性。旧中文 section-1 至 section-33、英文 section-1 至 section-30 保留。
- 当前公开文档相对链接检查无缺失；README 来源链接测试 5 项通过。历史证据及第三方文件保留，不把它们视为当日重新验收。
- 网站前端 27 项测试、TypeScript 与生产构建通过。手机 390px、iPad 1024px、桌面 1440px 检查中英文导航、目录、图片和下载入口；表单错误与焦点恢复已验证，未提交真实申请。
- 本任务没有触发完整 iOS 发布构建；发布状态和分发同步见 [CURRENT_STATUS](CURRENT_STATUS.md)。

The illustrated manuals share 20 top-level chapters and four real-interface images. Seven generator tests and five README-link tests pass; source bytes, hashes and legacy anchors are checked. Frontend tests, TypeScript, production builds and responsive keyboard/form checks are scoped to the website. No new full iOS release build or real beta application was performed.

新增文档 / New documents: this checklist; the archived engineering chronology; [screenshot provenance](assets/guide/README.md). The inventory below records the original document set.

## 清单 / Inventory

“核对保留”表示索引、链接与适用范围审查，无行为变化依据时保留原说明；不表示重新执行其全部命令或资格测试。Reviewed/retained means documentation scope/link review, not re-execution of every historical check.

| 文件 / File | 处理 / Treatment |
| --- | --- |
| `.github/PULL_REQUEST_TEMPLATE.md` | 已核对保留 / Reviewed and retained |
| `AGENTS.md` | 已核对保留 / Reviewed and retained |
| `CODE_OF_CONDUCT.md` | 已核对保留 / Reviewed and retained |
| `CODE_OF_CONDUCT.zh-CN.md` | 已核对保留 / Reviewed and retained |
| `CONTRIBUTING.md` | 已更新 / Updated |
| `CONTRIBUTING.zh-CN.md` | 已更新 / Updated |
| `FloeAgent/FloeApp/Resources/IDE/NOTICE.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/LinuxGuest/README.md` | 已更新 / Updated |
| `FloeAgent/Qualification/ExecutionDiagnostics/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/LiveAgentUI/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/LocalInference/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/LocalModels/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/NativeManagement/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/NativeMedia/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/NativeNode/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/NativePython/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/NativeShell/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/NativeSpeech/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/PencilPalette/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/Services/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/Qualification/Tests/PackageTests/Fixtures/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/Qualification/Tests/PackageTests/Fixtures/Repository/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/Qualification/TinyEMULinux/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/README.md` | 已更新 / Updated |
| `FloeAgent/ThirdParty/CADEngine/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/Collabora/EMBEDDING_INPUTS.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/Collabora/patches/xlsx-embedded-objects.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/DashIOS/PROVENANCE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/DocumentConversion/FONT_PROVENANCE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/DocumentConversion/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/EngineeringViewers/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/EngineeringViewers/fixtures/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/FloeShellEngine/PROVENANCE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/.github/ISSUE_TEMPLATE/bug_report.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/.github/pull_request_template.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/ACKNOWLEDGMENTS.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/CODE_OF_CONDUCT.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/CONTRIBUTING.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/FLOE_VENDOR.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/IntegrationTestHelpers/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXEmbedders/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXFoundationModels/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXGuidedGeneration/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXHuggingFace/Documentation.docc/Documentation.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLLM/Documentation.docc/Documentation.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLLM/Documentation.docc/adding-model.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLLM/Documentation.docc/evaluation.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLLM/Documentation.docc/using-model.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLLM/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/Documentation.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/developing.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/kv-cache-quantization.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/model-compatibility.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/porting.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/upgrade.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/using.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/Documentation.docc/wired-memory.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXLMCommon/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Libraries/MLXVLM/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/Tests/MLXLMTests/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/SKILL.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/concurrency.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/embeddings.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/generation.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/kv-cache.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/lora-adapters.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/model-container.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/model-porting.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/supported-models.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/tokenizer-chat.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/tool-calling.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/training.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/skills/mlx-swift-lm/references/wired-memory.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/tools/fixtures/FIXTURE-SCHEMA.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/MLXSwiftLM/tools/fixtures/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/NativeRuntimeArchive/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/NativeRuntimeArchive/ios-wheelhouse/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/NativeRuntimeArchive/recipes/pandas-runtime-release.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/PHPWASI/PROVENANCE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/RoyalVNCKit/FLOE_PATCHES.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/RubyWASI/PROVENANCE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/TinyEMU/LICENSE-INVENTORY.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/TinyEMU/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/TinyEMU/guest-image/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/TinyEMU/licenses/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/VideoEditorKit/FLOE_PROVENANCE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/VideoEditorKit/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/VideoEditorKit/Sources/VideoEditorKit/VideoEditorKit.docc/VideoEditorKit.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/WasmKit/FLOE_PATCHES.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/WasmKit/Sources/WAT/Docs.docc/Docs.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/WasmKit/Sources/WasmKit/Docs.docc/Docs.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/WasmKit/Sources/WasmParser/Docs.docc/Docs.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/ZLImageEditor/CHANGELOG.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/ZLImageEditor/FLOE_PROVENANCE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/ThirdParty/ZLImageEditor/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/scripts/fixtures/OFFICE_NATIVE_PROBE.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/scripts/office_real_simulator/tests/fixtures/zxing/README.md` | 历史/第三方/验收原始记录保留 |
| `FloeAgent/scripts/tests/README_BUILD191_HARNESSES.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/scripts/tests/local_model/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/scripts/tests/media_review/README.md` | 已核对保留 / Reviewed and retained |
| `FloeAgent/scripts/tests/pptx/README.md` | 已核对保留 / Reviewed and retained |
| `PRIVACY.md` | 已核对保留 / Reviewed and retained |
| `PRODUCT.md` | 已核对保留 / Reviewed and retained |
| `README.md` | 已更新 / Updated |
| `README.zh-CN.md` | 已更新 / Updated |
| `SECURITY.md` | 已核对保留 / Reviewed and retained |
| `SECURITY.zh-CN.md` | 已核对保留 / Reviewed and retained |
| `SUPPORT.md` | 已更新 / Updated |
| `SUPPORT.zh-CN.md` | 已更新 / Updated |
| `capability-hub/LANGUAGES.md` | 已核对保留 / Reviewed and retained |
| `capability-hub/packages/floe-lua/5.4.8/PROVENANCE.md` | 已核对保留 / Reviewed and retained |
| `docs/ACCEPTED_SDK_RELEASE_RECOVERY.md` | 已核对保留 / Reviewed and retained |
| `docs/ARCHITECTURE_LOCAL_SHELL.md` | 已核对保留 / Reviewed and retained |
| `docs/ARCHITECTURE_OVERVIEW.md` | 已更新 / Updated |
| `docs/CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md` | 已更新 / Updated |
| `docs/CREATIVE_MODE_AND_ASSET_ARCHITECTURE.zh-CN.md` | 已更新 / Updated |
| `docs/CURRENT_STATUS.md` | 已更新 / Updated |
| `docs/DESIGN_NOTES_PENCIL.md` | 已核对保留 / Reviewed and retained |
| `docs/DOCUMENTATION_REFRESH_20261005.md` | 已核对保留 / Reviewed and retained |
| `docs/FEATHER_SOURCE.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_1_7_24_CREATIVE_TOOLS.md` | 已更新 / Updated |
| `docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md` | 已更新 / Updated |
| `docs/FLOE_1_7_CHANGELOG_DRAFT.md` | 已更新 / Updated |
| `docs/FLOE_1_7_COMPATIBILITY.md` | 已更新 / Updated |
| `docs/FLOE_1_7_CONTINUATION_STATUS.md` | 已更新 / Updated |
| `docs/FLOE_1_7_DOCUMENTATION_AUDIT.md` | 已更新 / Updated |
| `docs/FLOE_1_7_IMAGE_EDITOR_INTEGRATION.md` | 已更新 / Updated |
| `docs/FLOE_1_7_IMPLEMENTATION_STATUS.md` | 已更新 / Updated |
| `docs/FLOE_1_7_MIGRATION.md` | 已更新 / Updated |
| `docs/FLOE_1_7_MIND_MAPS.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_1_7_NATIVE_PACKAGE_COMPLETION_PLAN.md` | 已更新 / Updated |
| `docs/FLOE_1_7_NEXT_RELEASE_STATUS.md` | 已更新 / Updated |
| `docs/FLOE_1_7_NEXT_ROUND_HANDOFF.md` | 已更新 / Updated |
| `docs/FLOE_1_7_NODE_RUNTIME.md` | 已更新 / Updated |
| `docs/FLOE_1_7_PLATFORM_AND_OFFICE_SCOPE.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_1_7_QUALIFICATION_MATRIX.md` | 历史实施记录保留 |
| `docs/FLOE_1_7_VIDEO_EDITOR_INTEGRATION.md` | 已更新 / Updated |
| `docs/FLOE_BROWSER_PROTOCOL.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_CAD_AND_DRAWING_ASSISTANT.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_CONCURRENT_EDITING.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_ENGINEERING_VIEWERS.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_GITEE_RELEASE_MIRROR.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_IDE_AND_LANGUAGES.md` | 已更新 / Updated |
| `docs/FLOE_IMAGE_EDITOR_DESIGN.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_LINUX_DOWNLOAD_SOURCES_20260930.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_LINUX_GUEST_BACKEND.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_LINUX_GUEST_IMAGE_BUILD.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_LINUX_GUEST_IMAGE_MANIFEST.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_MEDIA_WORKBENCH.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_PHASE2_2026_09_21.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_PORT_MANAGEMENT.md` | 已更新 / Updated |
| `docs/FLOE_RDP.md` | 已核对保留 / Reviewed and retained |
| `docs/FLOE_SHELL_TOOL_ROUTES.md` | 已核对保留 / Reviewed and retained |
| `docs/HARNESS_TIER3_DESIGN.md` | 已核对保留 / Reviewed and retained |
| `docs/IDE_GITHUB_ACTIONS.md` | 已核对保留 / Reviewed and retained |
| `docs/IDE_TEST_HOST_RECOVERY.md` | 已核对保留 / Reviewed and retained |
| `docs/INTERNAL_PROMPT_AUDIT.md` | 历史实施记录保留 |
| `docs/LOCAL_SHELL_IMPLEMENTATION_2026-09-12.md` | 历史实施记录保留 |
| `docs/MAIL_CONNECTOR.md` | 已核对保留 / Reviewed and retained |
| `docs/MEDIA_MODEL_CATALOG_2026-09-08.md` | 已核对保留 / Reviewed and retained |
| `docs/NOTES_OFFICE_PREVIEWS.md` | 已核对保留 / Reviewed and retained |
| `docs/NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md` | 历史实施记录保留 |
| `docs/OFFICE_FRONTEND_ACCEPTANCE.md` | 历史实施记录保留 |
| `docs/OFFICE_SCREENSHOT_INDEX.md` | 已核对保留 / Reviewed and retained |
| `docs/PDF_SKILL_HUB_IMPLEMENTATION.md` | 已更新 / Updated |
| `docs/PHASE2_adapter.md` | 历史实施记录保留 |
| `docs/PHASE2_assistant.md` | 历史实施记录保留 |
| `docs/PHASE2_component.md` | 历史实施记录保留 |
| `docs/PHASE2_documents.md` | 历史实施记录保留 |
| `docs/PHASE2_engine.md` | 历史实施记录保留 |
| `docs/PHASE2_git.md` | 历史实施记录保留 |
| `docs/PHASE2_migration.md` | 历史实施记录保留 |
| `docs/PHASE2_upgrade.md` | 历史实施记录保留 |
| `docs/PLAN_LOCAL_SHELL.md` | 已核对保留 / Reviewed and retained |
| `docs/PUBLIC_BETA_PREPARATION.md` | 已更新 / Updated |
| `docs/README.md` | 已更新 / Updated |
| `docs/RUNTIME_LIFECYCLE_ACCEPTANCE.md` | 历史实施记录保留 |
| `docs/SKILL_ROUTING_UPGRADE_WORK.md` | 已核对保留 / Reviewed and retained |
| `docs/TINYEMU_RUNTIME_V2.md` | 已核对保留 / Reviewed and retained |
| `docs/TOOL_CLOSURE_IMPLEMENTATION.md` | 已核对保留 / Reviewed and retained |
| `docs/USER_GUIDE.md` | 已更新 / Updated |
| `docs/USER_GUIDE.zh-CN.md` | 已更新 / Updated |
| `docs/VIDEO_CREDENTIAL_AUDIT.md` | 历史实施记录保留 |
| `docs/WORKFLOW_UPGRADE.md` | 已更新 / Updated |
| `docs/WORKFLOW_UPGRADE_IMPLEMENTATION.md` | 已更新 / Updated |
| `docs/evidence/floe-1.7/SCREENSHOTS.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/build172-repair/notes-83cbc383/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/build172-repair/notes-9e4434ca/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/build256/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/execution-stall-149/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/interface/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/localization-151/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/notes/render-regressions-298/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/notes/render-regressions-f5/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/notes/verified-455/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/floe-1.7/release-156/distribution-recovery.md` | 历史/第三方/验收原始记录保留 |
| `docs/evidence/workflow-upgrade-20260909/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/history/USER_GUIDE.pre-20261005.md` | 历史/第三方/验收原始记录保留 |
| `docs/history/USER_GUIDE.zh-CN.pre-20261005.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/agent-demo-build175/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/agent-demo-build175/review-demo.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build241/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build241/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build241/review-notes.zh-Hans.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build243/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build243/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build244/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build245/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build246/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build247/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build248/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build249/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build250/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build251/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build252/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build253/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build254/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build255/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build255/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build256/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build256/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build257/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build257/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build258/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build258/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build259/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build259/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build260/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build260/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build262/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build263/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build264/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/build265/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/privacy-and-access.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/review-assets.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/review-notes.en-US.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/review-walkthrough.md` | 历史/第三方/验收原始记录保留 |
| `docs/public-beta/sample-files/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build178-feedback/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build178-feedback/cad-ink/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build178-feedback/cad-layout/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build178-feedback/full-app-2e2a34c9/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build178-feedback/full-app-955e346a/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build178-feedback/full-app-a22e8c3e/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build179-release/runtime/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build179-release/sdk27-notes/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build184-release/native-notes/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build185-release/app-ui/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build185-release/native-covers/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build186-release/app-ui/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build186-release/native-covers/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build187-release/native-covers/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build187-release/notes-fixture-repair.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build188-release/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build189-release/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build190-release/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build191-feedback/cleanup-retirement.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build191-feedback/code-checks.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build191-feedback/local-model.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build191-release/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build202-release/build202-lean-build-failure.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build203-release/build203-lean-build-failure.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build204-release/build204-delivery.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build205-release/build205-bootstrap-failure.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build206-release/build206-compile-failure.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build206-release/office-host.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build209-release/build209-compile-failure.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/build214-release/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/linux-guest-image/2026-09-20-component-ci-35501535251.md` | 历史/第三方/验收原始记录保留 |
| `docs/qualification/office-simulator-stage/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/HISTORY.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/README.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_36.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_37.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_38.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_39.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_40.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_41.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_42.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_43.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_44.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_45.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_46.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_47.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/beta/RELEASE_1.7.0_BETA_48.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/builds/BUILD_226_DEV_TEMPLATE_SOURCE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/builds/BUILD_226_LINUX_TEMPLATE_DISTRIBUTION.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/FLOE_1_7_23_MEDIA_WORKBENCH.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/FLOE_1_7_24_BUILD265_CAD_CANVAS.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.87.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.88.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.89.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.90.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.91.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.92.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.93.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.94.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.95.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.96.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.97.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.98.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.4.99.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.5.0.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.5.1.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.5.2.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.5.3.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.0.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.1.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.2.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.3.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.4.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.5.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.6.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.6.7.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_173.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_174.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_175.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_176.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_177.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_178.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_179.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_180.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_181.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_182.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_183.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_184.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_185.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_186.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_187.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_191.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_192.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_193.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_194.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_195.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_196.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_197.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_198.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_201.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_202.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_203.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_204.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_205.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_206.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_208.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_209.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_210.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_211.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_212.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_213.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_214.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_215.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_216.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_217.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_218.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_219.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_220.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_221.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_222.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_223.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_224.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_225.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_226.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_227.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_228.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_229.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_230.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_231.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_232.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_233.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_234.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_235.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_236.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_237.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_238.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_239.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_240.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.0_BUILD_241.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.10_BUILD_251.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.11_BUILD_252.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.12_BUILD_253.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.13_BUILD_254.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.14_BUILD_255.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.15_BUILD_256.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.16_BUILD_257.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.17_BUILD_258.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.18_BUILD_259.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.19_BUILD_260.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.1_BUILD_242.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.20_BUILD_261.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.21_BUILD_262.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.22_BUILD_263.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.23_BUILD_264.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.24_BUILD_265.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.2_BUILD_243.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.3_BUILD_244.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.4_BUILD_245.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.5_BUILD_246.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.6_BUILD_247.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.7_BUILD_248.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.8_BUILD_249.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/notes/RELEASE_NOTES_1.7.9_BUILD_250.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_156_FEEDBACK_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_172_REPAIR_EXECUTION.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_1_7_LINUX_GUEST_NETWORK_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_1_7_REPAIR_LIFECYCLE_MLX_IDE_OFFICE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_229_LOCAL_PROMPT_BUDGET.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_229_MLX_GDN_PREFILL_CRASH_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_231_LINUX_LIFECYCLE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_231_MLX_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_231_OFFICE_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_232_DEVICE_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_233_DEVICE_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_233_LOCAL_MODEL_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_233_OFFICE_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_235_FEEDBACK_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_240_FEEDBACK_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_256_STABILITY.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_BUILD178_FEEDBACK_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_BUILD199_OFFICE_IDE_REPAIR.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_BUILD236_REPAIR_STATUS.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_BUILD_238_REPAIR_EVIDENCE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_DEVICE_FEEDBACK_REPAIR_20260921.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_FEEDBACK_2026_09_20.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/FLOE_LOCAL_VIDEO_TOOLCHAIN_REPAIR_2026-09-19.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/IMPLEMENTATION_1.5.0.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/repairs/STABILITY_1.4.88.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/BUILD_262_LOCAL_VERIFICATION.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/BUILD_263_LOCAL_VERIFICATION.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/LOCAL_BUILD_RELEASE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.24.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.25.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.26.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.27.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.28.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.29.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.30.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.31.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.32.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.33.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.41.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.42.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.45.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.46.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.47.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.49.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.50.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.73.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.74.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.75.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.76.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.77.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.78.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.79.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.80.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.81.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.82.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.83.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.84.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.85.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.86.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.87.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.4.88.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.0_BETA.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.10_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.11_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.12_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.13_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.14_BETA.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.15_BETA.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.1_BETA.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.2_BETA.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.5_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.6_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.7_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.8_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/testflight/TESTFLIGHT_1.7.9_CANDIDATE.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_CODE_AUDIT_20260909.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.5.2.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.5.3.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.6.0.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.6.1.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.6.2.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.6.3.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.6.4.md` | 历史/第三方/验收原始记录保留 |
| `docs/releases/verification/RELEASE_VERIFICATION_1.6.6.md` | 历史/第三方/验收原始记录保留 |
| `docs/validation/floe-156-feedback/samples/notes-search/generated.md` | 历史/第三方/验收原始记录保留 |
| `docs/validation/floe-156-feedback/screenshots/README.md` | 历史/第三方/验收原始记录保留 |
| `skill-hub/README.md` | 已核对保留 / Reviewed and retained |
| `skill-hub/sources/floe-network/SKILL.md` | 已核对保留 / Reviewed and retained |
| `skill-hub/sources/floe-office/SKILL.md` | 已核对保留 / Reviewed and retained |
| `skill-hub/sources/floe-pdf/SKILL.md` | 已核对保留 / Reviewed and retained |
| `skill-hub/sources/floe-video/SKILL.md` | 已核对保留 / Reviewed and retained |
