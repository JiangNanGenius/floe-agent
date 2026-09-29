# Build236 repair status / 修复状态

Updated: 2026-09-30. Candidate work; not a delivered App build.

## 已核对 / Reviewed

- `03ab10ae`: corrected the cloud workspace identifier schema to portable JSON Schema regex syntax; 13 focused tests passed. 云端工作区工具的标识符正则已修正，13 项针对性测试通过；尚非实际服务商端验收。
- `38afe1cc`: repeated invalid Linux metrics remain rejected, while duplicate diagnostics are suppressed until a valid sample or surface removal. 无效指标仍被拒绝，重复日志不再持续挤占诊断缓冲。
- `2659b28d`: native Office scheme callbacks and stop state share main-queue ownership; queued writes retain order and stream bounded chunks. Fourteen mock-WK native transport scenarios passed, including negative controls against the pinned original and prior patch. Office 原生通信的停止竞态、消息顺序与分块处理已修复；14 个原生模拟 WK 回归场景通过。这不是实际 Office 编辑器或 iPad 验收。
- `98ef7022`: concurrent first uses share one recovery pass; cancelled waiters leave promptly without interrupting durable recovery; stale UI reads cannot overwrite newer state. Linux 首次恢复合并、可取消等待及界面刷新代次保护已实现。430 XCTest and 227 Swift Testing tests passed. An extracted App reload harness passed object/SIL compilation and five runtime cases with stubs; it is not full-App compilation.

## Cloud host / 云端宿主

[Run 36600071346](https://github.com/JiangNanGenius/floe-agent/actions/runs/36600071346) builds the Office host from `2659b28d32119d193684bf766bfec282f52ff57d`. The run includes the native lifecycle regression and preserves its result. The build succeeded. [Verification run 36601587407](https://github.com/JiangNanGenius/floe-agent/actions/runs/36601587407) checked all 4,780 resources and matching scheme-overlay provenance. The host is now pinned; archive SHA-256: `6fdbb8ba0dfc477f28b3f32e7a747be819997d9d646ef1f42e87aac0eacfe435`.

云端构建与完整资源核验已通过，App 宿主版本已固定。云端产物已保留，本地备份下载仍在进行。

## Open items / 未完成

- PPT edit-mode exit has no matching current system crash stack. The proven transport defect is not established as the sole cause. PPT 编辑模式闪退仍待真机确认，不宣称已修好。
- Bundled CJK fonts cover a sampled Chinese string in macOS CoreText. That does not verify the iPad Office fallback path or the reported square glyphs. 字体方框仍未确认解决。
- Linux automatic download already uses the shared preparation service. The new recovery changes remove a reproduced concurrency defect, but device download and boot still require verification. 不把组件恢复测试等同真机下载、启动成功。
- Local model curation passed 6 prompt tests and 9 runtime/action-claim tests, including cloud isolation and sequential read-only tools. Broader tests retained failures also reproduced without the curation change (context compaction, conversation paging, receipt size and cancellation). The full suite is not green. Real-weight search-answer grounding remains unresolved from Build235. 本地精选工具的 15 项定向测试通过；扩大检查仍有可在基线复现的失败，不宣称全套通过，也不以脚本模型代替真实权重。
- Build236 tag `v1.7.0-beta.95` is fixed at `66e1d78a2de841e5383345527ccf60df35d1cc54`. [Release run 36602907252](https://github.com/JiangNanGenius/floe-agent/actions/runs/36602907252) failed full-App compilation: synchronous backend assembly awaited an actor-isolated progress-handler setter. No IPA or TestFlight upload was produced. Build237 is the recovery candidate; Build235 remains the last verified internal delivery. Build236 完整 App 编译失败、未交付，原标签保持不变；Build237 接续修复。
