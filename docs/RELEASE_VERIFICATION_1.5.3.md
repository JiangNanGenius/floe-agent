# Floe 1.5.3 / Build 134 — release verification

Immutable source: `5f9eeec8d80c6af74816391c49e0248757c8f239`; tag `v1.5.3`.

## Verified before release

- All app/extension versions and build numbers match; clean project regeneration and release preflight passed.
- Three metadata regression tests reject the previously accepted release-note string, missing translations and invalid minimum versions before signing.
- Cloud signing [completed](https://github.com/JiangNanGenius/floe-agent/actions/runs/34233479948). Catalog locale types and ZIP digests were checked locally; published ZIP bytes were not changed.
- Official Skill Hub [tag verification passed](https://github.com/JiangNanGenius/floe-agent/actions/runs/34233560200); [main verification passed](https://github.com/JiangNanGenius/floe-agent/actions/runs/34233560131).
- Conversion/provider source is unchanged from the focused simulator passes recorded for [1.5.2](RELEASE_VERIFICATION_1.5.2.md). The actual PDF [rendered output](images/workflow-upgrade/document-conversion-pdf.png) preserves Chinese headings, styles, lists and tables. Long-document testing preserved all 200 markers across 42 pages and distinct Unicode characters without modifying the 48,122-character source.
- Dependency licenses, modified export font provenance, provider request boundaries and actual UI screenshots are linked in the [complete upgrade record](WORKFLOW_UPGRADE.md).

## Cloud and Apple gates

- [Full CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/34233559888): passed. 1,007 SwiftPM test executions, 122/122 app regressions, Linux build, App Store SDK compatibility build, secret scan, SBOM and 152-dependency license inventory passed.
- [Release build, signing and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/34233559897): all jobs passed, including SwiftPM tests, simulator/device builds, app regressions, source/binary scans, dependency checks, accepted-SDK rebuild/regressions (122/122 app tests passed on each SDK), package verification, signing, upload and paired GitHub release publication.
- Apple processing: [discovery confirmed `VALID`](https://github.com/JiangNanGenius/floe-agent/actions/runs/34246903131), version 1.5.3, build 134, build ID `d95e0909-c75f-44f9-81dc-eee9ba8b48cc`. Upload processing completed with no errors or warnings.
- [Floe QA internal group visibility verified](https://github.com/JiangNanGenius/floe-agent/actions/runs/34247056003): exactly one group, `Floe QA`, internal=true, public link not enabled; zero unexpected groups. Marketing version 1.5.3 and build 134 match.

Verified on 2026-09-09 (Australia/Sydney): **1.5.3 (134) is available to the existing Floe QA internal TestFlight group.** This is internal TestFlight availability, not public App Store publication or physical-device acceptance.

## Device test priorities / 真机测试重点

1. 打开 TestFlight 确认版本与构建号，再打开旧聊天，检查是否直接显示最新内容。
2. 展开几万字的思考过程，滚动、查看最新、全屏，再折叠；单独测试长输入和长 Markdown 正文，并注明是哪一种卡顿。
3. 让模型一次写入较长文本文件，观察工具参数传输和等待阶段；检查最终文件内容。断网和真实服务端限制仍可能导致失败。
4. 将同一个 Markdown 文件转为 Word、PDF、HTML、RTF，再转回 Markdown；检查标题、表格、图片、中文、最后一段和源文件是否保留。扫描 PDF 先运行 OCR。
5. 在 iPhone 横竖屏进入画布，创建并编辑 SVG/HTML 节点，确认生成任务菜单顺序、键盘关闭和触控位置。
6. 长按侧栏/工作台的聊天进入多选，测试批量归档与恢复；删除使用临时测试聊天。
7. 从文件管理打开不同聊天/项目工作区，直接阅读右侧 PDF，再切换全屏返回。
8. 长工具调用期间观察聊天、画布和画中画的阶段、耗时、最近活动；测试切后台后回到当前任务是否刷新。
9. 打开插件发现/已安装与更新界面，确认简洁版本提示；在模型列表选择新火山/阿里预设，用自己的已开通账户验证实际生成。

## Unfinished parts of the overall upgrade

The complete offline Word/Excel/PowerPoint editing engine remains unintegrated after its separate native qualification stopped at the disk reserve. PowerPoint creation, full charts, embedded attachments, advanced formatting and exact object placement are not claimed by this release. Existing PowerPoint slide/note text fields can be inspected and updated; this is not full presentation authoring. Semantic file conversion is available for testing with explicit format limits. Device performance, live model generation/region permissions and physical Picture in Picture behavior remain separate acceptance checks.
