# Settings parity acceptance matrix (iOS → Android)

> Current-stage note (2026-10-21, G02-R2): the implementation-state counts below
> describe the 2026-10-19 snapshot, not the published Alpha3. Alpha3's actual App
> settings list exposes eight categories: General, Model & Provider, Skills &
> Connectors, Memories & Personalization, Usage, Privacy, Web Search, and
> Diagnostics & About. Its wide list/detail layout and representative provider
> editor modal were exercised in R1. This does not mark every category body or
> operation accepted. Preserve the dated row evidence below; use current source,
> the operation ledger and the [current plan](../../docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md#g02-current-plan)
> for the 17-operation R2 scope. Presentation intent and feature-stage ownership
> remain applicable; old `N`/`P`/three-row counts are not current implementation facts.

Status: 2026-10-19, documentation only. This matrix is an acceptance and coverage ledger, not a build, device, runtime or release qualification.

It accounts for every `SettingsSection` case in the current iOS source and records the current Android state against the actual iOS presentation modifiers. It deliberately does **not** claim that all categories are implemented or aligned: the Android app currently exposes three category rows, one of which is still a placeholder.

Authority order used here:

1. Current iOS source: [`SettingsRootView.swift`](../../FloeAgent/FloeApp/Settings/SettingsRootView.swift) (category enum, `visibleCases`, routing) and the referenced views/modifiers.
2. Current implementation plan §22.8 and §23: [`FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md`](../../docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md).
3. Current recorded progress: [`FLOE_ANDROID_PROGRESS.zh-CN.md`](../../docs/FLOE_ANDROID_PROGRESS.zh-CN.md).
4. Current Android source: [`SettingsSheet.kt`](../app/src/main/kotlin/com/floe/android/SettingsSheet.kt), [`FloeRoutes.kt`](../core/designsystem/src/main/kotlin/com/floe/android/design/FloeRoutes.kt) and the feature modules.

Where an older settings report conflicts with this file, this file records the corrected position. Older reports remain frozen historical evidence and are not rewritten by this document.

## 1. Counts, levels and status vocabulary

Source-verified counts:

- iOS `SettingsSection` has **20** enum cases.
- `SettingsSection.visibleCases` excludes `sourceControl`, so **19** categories are visible in the native Settings list.
- Android `FloeSettingsSection` currently has **3** rows: `GENERAL`, `PROVIDERS`, `DIAGNOSTICS`.
- The remaining **17** native cases are accounted for below as hidden, excluded, or not implemented. They are not silently omitted.

Presentation levels:

- **L0** — the Settings container itself: page-sized sheet, wide split view, compact stack, closing and reopening.
- **L1** — the category row and selection path: wide master-detail (`SPLIT`) or compact push (`PUSH`). All visible native categories use one of these; category selection is not a modal.
- **L2** — the category detail page and its immediate secondary presentation (`SHEET`, `FSC`, `CDLG`, `ALERT`, `POPOVER`, `MENU`, `SHARE`, `INLINE`).
- **L3** — a nested child page, sheet, popover or alert opened from L2.

Presentation vocabulary:

- `SPLIT` — category list and detail side by side.
- `PUSH` — standard NavigationStack detail.
- `SHEET` — `.sheet`, including `presentationSizing(.page)`.
- `FSC` — `.fullScreenCover`.
- `CDLG` — `.confirmationDialog`; on iPad this is an anchored menu, on iPhone an action sheet.
- `ALERT` — `.alert`.
- `POPOVER` — `.popover` anchored to a control.
- `MENU` — `Picker` menu presentation.
- `SHARE` — system share sheet.
- `INLINE` — status or error inside the page, not a modal.

Android state vocabulary:

- **R** — implemented in current Android source, compiled, and actually rendered/tested in the App at the stated scope. Root-level only unless stated.
- **P** — placeholder body, not a real feature page.
- **A** — authored source and/or test inventory only; not compiled or executed in this round.
- **N** — not implemented in Android; no category row.
- **H** — hidden native category, intentionally not copied as a Settings row.
- **X** — excluded by the confirmed Android product/platform boundary, not a generic omission.

Two rules apply to every row:

- Non-modal iOS detail pages stay `PUSH`/`SPLIT`; they are not forced into modals merely because the user asked for iOS secondary-menu parity.
- Android background execution must use its real lifecycle and notification mechanisms. Do not copy the native PiP status/control as a background keepalive technique; ordinary media PiP is a separate feature.
- G14 may polish materials, icons and geometry, but cannot defer the fundamental structure or the current G02 bindings listed in §5.

## 2. Corrected root position

These corrections supersede the settings-root conclusions in the earlier two-column report:

1. **The wide two-pane layout was present before the repair.** The initial tablet screenshot already contained the category column and a selected detail. The defect was a state-path conflation: one saveable flag carried both wide column-collapse and compact push semantics, so closing/reopening and width changes could hide the category column. The repair separated those states.
2. **Root layout and presentation were actually built and tested.** Both full and play debug Apps built; the actual App passed **23 root checks** with **37 screenshots**. That evidence covers wide, portrait, compact, rotation, Back, reopen, explicit entry, Chinese light and English light/night. It is root-layout evidence only.
3. **The compact extra column button was removed, not deferred to G14.** The current compact toolbar has no column toggle; the wide header retains the collapse control and the detail header retains the restore control. This was actual-tested (`compact has no column toggle`, `compact column button remains absent`).
4. **Ordinary reopen and recreation are different paths.** Ordinary gear open restores wide two panes with General selected, or the compact list root. A later focused 18-check actual App run verified this native-reopen correction; the earlier 23-check run exercised the now-superseded category retention. A valid explicit entry opens the selected category (compact: detail directly). Rotation, window resize or recreation of an already-visible sheet preserves the current navigation state.
5. **Root tests used the existing prebuilt Swift native closure.** They do not prove a new native build, provider runtime, credential gateway, real cloud request or service binding.
6. **Two source changes followed the root receipt.** The providers category uses the existing antenna glyph, and ordinary reopening selects General like a fresh native sheet. Both later changes were included in new full/play debug builds and verified in the focused 18-check actual App run. The earlier APKs and screenshots remain prior-source evidence and must not be relabelled as current-source evidence.
7. **Provider baseline and later modal fixes are different evidence.** The earlier standalone provider UI baseline passed 15 tests in each of zh/light and en/dark with 14 captures each. The later three modal source changes (purpose chooser, protocol menu, save-only alert) are authored only: 61 JVM tests, 21 instrumentation tests and 15 captures are inventoried, not executed. Those counts are a minimum inventory, not a cap.
8. **Current G02 ownership is broader than the earlier matrix implied.** Provider/model, conversation/history, Skills/MCP, approvals, web search and preferences are current G02 binder scope. They are not deferred to later G0x goals. The remaining categories below follow their real feature stage in the approved plan; this correction does not expand the current implementation or promote any operation to complete.

## 3. L0 container parity

| Aspect | iOS actual | Android actual | State | Remaining gap |
| --- | --- | --- | --- | --- |
| Container | `SettingsRootView` is presented from the App as `.sheet` with `.presentationSizing(.page)` (`FloeAgentApp.swift` L497–504). | `FloePageSheet` with a calibrated top inset; full-width bottom-style page sheet on tablet and phone. | R | Android container is an approximation of the native page sheet, not pixel parity. It is recorded as a local platform adaptation; G14 may refine its materials but must not restructure it. |
| Wide L1 | `NavigationSplitView(columnVisibility: .all)`; list column, non-empty detail; first category preselected (`SettingsRootView.swift` L82–89). | `Row` with a 280–360 dp sidebar and weighted detail when `maxWidth >= 600 dp`; both panes on ordinary open. | R | Sidebar width and sheet top inset are calibrated values, not native points. |
| Compact L1 | `NavigationStack` with `NavigationLink` rows and a `navigationDestination` (`SettingsRootView.swift` L117–135). | Internal `compactDetailOpen` stack with Back; no column toggle. | R | Android uses a composed stack inside the sheet rather than a native navigation container. |
| Ordinary open | On iPad, a fresh sheet starts wide split with General selected (native @State initializer). | Wide both panes with General selected; compact list root. | R (focused follow-up) | Later actual App checks verify General on ordinary reopen, explicit entry and visible recreation. Earlier category-retention assertions remain historical. |
| Explicit entry | Valid section selection opens the category; compact opens its detail directly. | Valid deep link selects the category, clears wide collapse and opens compact detail. Invalid/empty entry follows ordinary open. | R | Source + root checks; no provider body binding. |
| Recreation | Rotation, window resize or reconstruction of a visible sheet keeps current navigation state. | `lastPresented` distinguishes a real hidden→visible transition from recreation; compact push and wide collapse survive rotation/resize. | R | Process-death restore and predictive-back animation were not tested. |
| Close / Back | Done, swipe-down and system dismissal; Back inside compact pops detail first. | Done, scrim, system Back; compact Back pops to list, wide Back dismisses the sheet. | R | Root checks cover actual key Back and resize, not predictive gesture animation. |
| Scroll ownership | Each `Form`/`List` owns its scroll. | Root detail body is currently wrapped in a single `verticalScroll`; the placeholder body is small. Provider destination has its own scroll and must not be nested in an unbounded parent. | R / P | **Structural G02 work:** when binding providers, use a finite weighted body with exactly one scroll owner per list/form. Do not defer this to G14. |
| Header and Add | Native provider detail uses the navigation large title plus a trailing Add control (`ProviderListView.swift` L21–27, L84). | Root detail header supplies the large title; provider placeholders have no Add control. Provider destination expects a host title and supplies its own plus toolbar. | P | **G02:** inspect actual native title/Add ordering before composing them; use explicit header/action slots. Do not stack a duplicate root title above the feature toolbar or lose the wide sidebar restore control. |

## 4. Category matrix

Target stages are derived from the owning feature family in plan §23.2–§23.3: files → G04, execution/background execution → G03, canvas → G09, data management/diagnostics/remote → G11, and so on. The plan does not define a separate per-row Settings stage, so the G02 rows follow the current G02 binder contract recorded in §2. This mapping assigns ownership; it does not promote any row to implemented or tested.

`L1` is `SPLIT` wide / `PUSH` compact for every visible row. The `sourceControl` row is hidden in iOS and is not copied to Android as a row.

| # | Native category | iOS L1 | iOS L2 (actual modifier) | iOS L3 | Android current | Target | State and evidence gap |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `general` — General 通用 | SPLIT / PUSH | Form: appearance, language `MENU`, voice input, running input, answer quality, content-updates `PUSH`, reduce-motion `MENU` (`GeneralSettingsView.swift` L34–101). | Whisper form; content-updates page. | L1 `SPLIT`/`PUSH` actual-tested; L2 only theme preview/segmented + read-only language row; L3 absent. | G02 (chat/default preferences); G11 (speech/content/system integration); G01 shell baseline. | **R (partial L2).** Missing language override, Whisper, recognition language, send method, answer-quality toggle, content updates and reduce motion. No placeholder claims. |
| 2 | `personalization` — Memories & Personalization 记忆与个性化 | SPLIT / PUSH | `MemoryView`: search/list, add, profile, SOUL.md, pending review; delete and apply-organization `CDLG` (`MemoryView.swift` L463, L477, L491, L562). | `SHEET` + `NavigationStack` forms for add/profile/SOUL/review. | N — L1/L2/L3 absent; no row. | G02 (memory/persistence). | **N.** No Android source, page, storage binding or screenshots. |
| 3 | `internalPrompts` — Internal Prompts 内部提示词 | SPLIT / PUSH | Read-only `Form`: installed version/digest/source, check/install/rollback actions, auto-update toggle, inline errors (`InternalPromptsSettingsView.swift` L22–250). | None. | N — L1/L2/L3 absent; no row. | G11 (signed content-update integration and full-code closure; no separate plan family). | **N.** No Android page or content-update binding. |
| 4 | `providers` — Models & Providers 模型与供应商 | SPLIT / PUSH | Provider list; Add `CDLG`; capability-review `SHEET`; editor `SHEET` + `presentationSizing(.page)`; delete-failure `ALERT` (`ProviderListView.swift` L84–117). | Purpose-role `CDLG`; protocol `MENU`; supplier `POPOVER`; model-manager/model-editor/offer `SHEET`s; save-failure `ALERT` (`ProviderEditorView.swift` L138–232). | L1 `SPLIT`/`PUSH` actual-tested; L2 is a placeholder “model status: unconfigured”, not a provider list; feature module source exists but the App has no module dependency; L3 authored only. | G02 (real provider/model binding). | **P + A.** Provider baseline passed 15/15 per locale (zh/light, en/dark) with 14 captures each on earlier source. Later purpose/protocol/save-alert fixes are authored: 61 JVM / 21 instrumentation / 15 captures, unexecuted. Same-frame same-error save retry is still an open, source-proven risk; do not count it passed. Purpose anchor to the real Add control is a deliberate narrow usability deviation from the observed native anchor. Save alert is save-only; connection/discovery failures stay inline. |
| 5 | `auxiliary` — Auxiliary Models 辅助模型 | SPLIT / PUSH | Form: general auxiliary LLM, vision, package review, shared/generation/editing model pickers (`AuxiliarySettingsView.swift`, `AuxiliaryModelsView.swift`). | None. | N — L1/L2/L3 absent; no row. | G02 (auxiliary model configuration). | **N.** No Android page or model-routing binding. |
| 6 | `localModels` — Local Models 本地模型 | SPLIT / PUSH | Form with Beta badge; confirmation `CDLG` for removal (`LocalModelsSettingsView.swift` L419). | None. | X — not a Settings row. | Excluded by product boundary. | **X.** Android ships no local LLM (plan §1.1); this is not a generic functional omission and does not imply a future Android local-model page. |
| 7 | `canvas` — Canvas 画布 | SPLIT / PUSH | Form: assistant/vision model pickers, Apple Pencil preferences, organization defaults, canvas grid/snap/sync; save-error `ALERT` (`SettingsRootView.swift` L230–297). | None. | N — L1/L2/L3 absent; no row. | G09 (canvas), with G02 model-preference support. | **N.** No Android settings page. |
| 8 | `webSearch` — Web Search 网页搜索 | SPLIT / PUSH | Form + editor `SHEET` (`WebSearchSettingsCenter.swift` L233). | Editor form. | N — L1/L2/L3 absent; no row. | G02 (web-search tool settings). | **N.** No Android page or service binding. |
| 9 | `permissions` — Permissions 权限 | SPLIT / PUSH | Form: default mode, approval model; full-access `ALERT` (`AgentPermissionsView.swift` L25–120). | None. | N — L1/L2/L3 absent; no row. | G02 (approval binding). | **N.** Approval behavior remains current G02 work; no Android settings surface yet. |
| 10 | `appleCapabilities` — Apple Capabilities | SPLIT / PUSH | Form (`AppleCapabilitiesSettingsView`). | None. | X — not a Settings row. | Excluded by platform boundary. | **X.** Apple-only capability surface; not an Android parity target. |
| 11 | `privacy` — Privacy 隐私 | SPLIT / PUSH | Form: biometrics preference, credential state/count, clear-history and clear-models `CDLG`s, diagnostics `SHARE` (`PrivacySecurityView.swift` L97–121). | System share sheet. | N — L1/L2/L3 absent; no row. | G02 (credentials/history); G11 (biometrics/share/diagnostic wrappers). | **N.** No Android page; credential/history semantics remain G02. |
| 12 | `execution` — Execution 执行环境 | SPLIT / PUSH | Form: environment manager `PUSH`, target `MENU`, stop-VM `CDLG` (`ExecutionEnvironmentView.swift` L95–127). | Environment manager pages. | N — L1/L2/L3 absent; no row. | G03 (Linux environments and jobs). | **N.** No Android page; execution environments belong to G03. |
| 13 | `backgroundExecution` — Background Execution 后台执行 | SPLIT / PUSH | Form: inline background-execution picker (`.pickerStyle(.inline)`); conditional PiP status section (`BackgroundExecutionSettingsView.swift` L31). | None. | N — L1/L2/L3 absent; no row. | G03 (background runtime/notification foundation). | **N.** No Android page; platform behavior and policy remain G03/G11 work. |
| 14 | `files` — Files 文件 | SPLIT / PUSH | Form: browse/manage `PUSH`, workspace list, remove-workspace `CDLG` (`FilesSettingsView.swift` L21, L84). | All-workspaces file browser. | N — L1/L2/L3 absent; no row. | G04 (files and SAF). | **N.** No Android settings page or workspace binding. |
| 15 | `sourceControl` — Source Control (hidden) | HIDDEN | `visibleCases` filters it out (`SettingsRootView.swift` L21); detail would route to `ConnectorsView` if reached. | Not reachable from the visible list. | H — no Settings row. | Capability split: Git/source control G04; Skills/MCP binding G02. | **H.** Do not copy a hidden native category merely for visual symmetry. The underlying Git integration remains planned (G04); Skills/MCP binding remains current G02 work and is not a reason to expose this row. |
| 16 | `sync` — Sync 同步 | SPLIT / PUSH | Form: master toggle, iCloud status, configuration sync, manual sync, status rows (`SyncSettingsView.swift` L11+). | None. | N — L1/L2/L3 absent; no row. | G11; cross-device sync remains gated by a separate user decision (plan §23.2). | **N (gated).** Do not advertise or implement a sync service by default. |
| 17 | `remote` — Remote 远程 | SPLIT / PUSH | Form + host-manager `SHEET` (`RemoteSettingsView.swift` L79). | Host-manager form. | N — L1/L2/L3 absent; no row. | G11 (SSH and remote hosts). | **N.** No Android page or host binding. |
| 18 | `usage` — Usage 用量 | SPLIT / PUSH | List: segmented dimension picker, optional model/provider `MENU`, token totals and breakdown (`UsageStatisticsView.swift` L37–44). | None. | N — L1/L2/L3 absent; no row. | G02 (model/run usage accounting). | **N.** No Android page or usage store binding. |
| 19 | `dataManagement` — Data Management 数据管理 | SPLIT / PUSH | Form: task-management `PUSH`, fonts `PUSH`, safe-cleanup `CDLG`, font-import `SHEET`, import error `ALERT`, font-removal `CDLG` (`DataManagementView.swift` L194–208, L318, L642–656). | Task list; font manager. | N — L1/L2/L3 absent; no row. | G11 (settings and data-management closure, P5.5). | **N.** No Android page or storage-metering binding. |
| 20 | `diagnostics` — Diagnostics & About 诊断与关于 | SPLIT / PUSH | Form: log-level `MENU`, license `PUSH`, export `SHARE`, feedback `SHEET`, full log `FSC` (`DiagnosticsAboutView.swift` L160–196). | License list; feedback form; full-screen log. | L1 `SPLIT`/`PUSH` actual-tested; L2 partial: shared-core status, debug-only component preview, version/distribution/about; L3 absent. | G11 (SET-FONT-DIAG, P5.5); G01 baseline. | **R (partial L2).** Missing log level, log buffer, export, feedback, licenses and full-log page. The component preview is debug-only and has no iOS product counterpart; it is not parity evidence. |

## 5. Crosscutting acceptance gates

These gates apply to the category rows above. They are structural or behavioral requirements, not optional G14 polish.

| Requirement | Actual iOS target | Android current | Gate / owner | Evidence needed |
| --- | --- | --- | --- | --- |
| Finite bounded body and one scroll owner | Each `Form`/`List` owns scrolling; sheets size their content to the presentation. | Root detail currently owns a single `verticalScroll`; provider destination has its own `verticalScroll` and must not be placed in an unbounded parent. | G02 provider binding, before App acceptance. | Empty, filled, loading, error, keyboard and long-list states at wide and compact widths; no infinite-height measurement or nested scroll. |
| Host large title and Add ordering | Native provider list has the navigation large title plus a trailing Add control; the feature does not draw a second title bar. | Provider destination expects a host-supplied title and supplies its own plus toolbar; placeholder has no Add control. | G02 provider binding. | Explicit header/action slots; no duplicate title, no lost wide sidebar restore, correct compact Back and Done order. Actual App screenshots after binding. |
| Actual window metrics for popover traits | Native popovers size against the presenting window; iPhone degrades to a sheet. | Provider destination already reads `LocalWindowInfo.containerSize` + density, not the narrow detail-column width. Protocol menu clamps to the live window and flips above/below. | G02 provider qualifier; preserve in any later embedding. | Wide tablet window whose detail pane is under 600 dp: nested menus still size and anchor against the real window. Anchors measured in the presenting window; no hardcoded screen coordinates. |
| Draft retention, Back and outside dismissal | Back closes the innermost menu; cancel does not submit; failure keeps the editor and recoverable content; success follows the save path. | Purpose menu and protocol menu close only themselves; save alert acknowledgement does not close the editor; form state is retained. Authored, not executed. | G02 provider qualifier. | Actual Back, outside tap, Cancel, OK, failed save and retry paths; no draft loss or accidental editor close. |
| Late-callback and epoch fencing | A failure from an older editor must not alert the current editor. | Save alert is keyed by editor identity + epoch; stale projections return null. | G02 provider qualifier. | Authored stale-editor, stale-epoch and connection-inline tests must actually run. The same-frame same-error retry remains an open accepted-save-attempt case: fix it at the accepted attempt event and pass a synchronous same-frame retry test alongside the existing asynchronous retry test. Recording the defect keeps this gate open. |
| Locale, theme, width and recreation | English and Simplified Chinese; light and dark; wide and compact; reopening and recreation. | Root checks cover English light/night, Chinese light, wide, portrait, compact, rotation, resize, reopen and explicit entry. Provider baseline covers zh/light and en/dark. | Current root evidence plus G02 binding. | No current evidence covers Chinese dark; the full matrix needs en/zh × light/dark × wide/compact, plus recreation and explicit deep link after provider binding. |
| Translucent layers and icons | Native materials and icon geometry are the visual reference. | Root glass/tonal layers and some icons are approximations. The antenna category glyph was built and actually rendered in the later focused root run; fine optical/material parity remains open. | G14 for fine material/icon work; G02 for current structural binding. | Per-surface material and icon matrix with actual screenshots. G14 cannot be used to defer the scroll, header, window-metric or binding gates. |
| No placeholders presented as complete | Native surfaces are backed by real state. | Only three Android rows exist; providers L2 is a placeholder; missing categories have no row. Diagnostics has a debug-only preview. | Product owner / each target stage. | Do not add a placeholder row or button to make the list look complete. A category appears only when its real page and state are implemented. |

## 6. Evidence ledger and non-claims

### 6.1 Root layout (current category rows)

- Both full and play debug Apps built successfully.
- Actual App root acceptance: **23 checks passed**, **37 screenshots**.
- Covered: wide initial split; wide category changes; explicit column collapse and restore; wide Back and reopen with both panes and selected provider; portrait resize and restore; compact independent list; no compact column button; compact push/Back; resize/rotation retention; compact system Back; explicit provider entry; ordinary gear ignoring a stale deep link; Night wide and compact; Chinese wide and compact.
- Limits: the run used the existing prebuilt Swift native closure. It is not a new native build, provider service binding, real cloud request, credential-gateway or full G02 runtime qualification. Physical Samsung behavior was not part of this root batch; compact was simulated by resizing the API 37 tablet.
- The antenna glyph and General-on-ordinary-reopen changes happened after this receipt. The 23-check APKs and screenshots keep their original source identity; old category-retention assertions are historical. The later focused run below supplies the current-source evidence.

### 6.1b Later focused root follow-up

- New full and play debug Apps built successfully; both exact APKs were saved and their pinned signer and imported native-library hashes verified. A signing-output parser mismatch was repaired against the actual verifier format; saved APKs were reused without another build.
- The actual API 37 App passed **18 focused behavior checks**: 9 wide, 6 compact and 3 Chinese, with 30 complete screenshots and matching UI trees. Ordinary reopen selects General; folding then reopening restores both panes; explicit entries keep their target; real rotation and visible compact-to-wide resize retain the current page. The antenna category glyph was visually reviewed in English and Chinese.
- These checks cover the later source changes; they are a separate run from the earlier 23 checks and must not be added into an independent total. English and Chinese light appearance were exercised; no new dark-theme or Chinese-dark qualification is claimed.
- Temporary app locale, display size and rotation were restored to their exact baseline; the owned App process and emulator were stopped, data preserved. Two duplicate internal APK outputs were removed after verified external export. Shared caches retain an identified next use in the queued G02 builds.
- Scope remains Settings root only, with the existing imported Swift native pair. Provider feature binding, nested-menu qualification, new V3 native runtime and full G02 behavior remain open.

### 6.2 Providers feature

- Earlier standalone provider UI baseline: 15 tests passed in zh/light and 15 in en/dark; 14 complete captures per locale. This is synthetic component UI evidence, not App binding.
- Later source changes for the purpose chooser, protocol menu and save-only alert are **authored only**: 61 JVM tests, 21 instrumentation tests and 15 captures are inventoried. No compile, test run, APK, device render or qualifier result exists for this later source in this round.
- Same-frame same-error save retry: the current alert effect is keyed by editor identity/epoch, failure message and in-flight state. If a save attempt fails synchronously with the same message inside one UI frame, the effect can coalesce and suppress the re-alert after an acknowledgement. This source-proven defect requires a fix and an actual accepted-save-attempt test, alongside the existing asynchronous retry case. Recording the defect keeps the gate open; it does not satisfy acceptance.
- Anchoring the purpose popup to the actual Add control is a deliberate narrow usability deviation from the observed native capture, not an exact-anchor parity claim.
- The save alert is save-only. Connection and discovery failures remain inline.
- No provider App binding exists: the app module does not depend on the providers feature module, and the Settings providers body is still the placeholder.

### 6.3 Other categories

- Beyond the three current rows, no Android row exists for the 14 unimplemented visible categories, the hidden `sourceControl` category, or the two excluded visible categories.
- No source, runtime, screenshot or service-binding claim is made for those categories in this document.
- `localModels` and `appleCapabilities` are excluded by the confirmed Android product boundary; they are not pending generic parity rows.
- `sourceControl` is hidden in native Settings. Git/source-control capability remains planned in G04; Skills/MCP binding remains current G02 work elsewhere.

### 6.4 Documentation scope

This document was produced by static source and document reconciliation. No build, device, emulator, ADB, credential, network, version, upload, Git or release action was performed.

### 6.5 Source-backed domain exposure gaps

The shared services already contain the original memory/personalization stores and aggregate run-usage query, but the current bridge has no Settings-facing memory or global-usage operations. Model-routing preferences are also distinct from persisted global agent defaults: the latter use the original settings store. These are open G02 binding/contract gaps, not permission to invent generic preference writes or mark missing pages complete. Auxiliary model configuration can reuse the actual validated model-selection preferences; active-task policy updates do not replace global defaults. Speech, content updates, biometrics and diagnostic export retain their corresponding system-integration stage.

## 7. Exit criteria by stage

- **G02 (current binding):** replace the providers placeholder with the real provider/model list, editor, service and secure credential path; bind conversation/history, Skills/MCP, approvals, web search and preferences; satisfy the scroll, header, window-metric, draft/Back and epoch gates; rebuild the App with the antenna category icon and General-on-ordinary-reopen behavior; execute the later provider modal tests and actual App paths; fix the same-frame retry defect and pass the synchronous and asynchronous retry checks on device. Root checks alone are not G02 closure.
- **G03:** implement `execution` and `backgroundExecution` pages with real environment/background state. G03 owns the Linux and background-runtime foundation.
- **G04:** implement `files`; retain Git/source-control capability even though the native Settings row stays hidden.
- **G09:** implement `canvas` settings with real model/preference storage.
- **G11:** implement `internalPrompts`, `sync` (only if the separate sync gate opens), `remote`, `dataManagement` and the full `diagnostics` surface; complete the settings/data-management closure.
- **G14:** finish material, icon, typography, motion and fine geometry polish. G14 may not be used to defer the structural or current G02 binding gates above.
- **Excluded/hidden:** `localModels` and `appleCapabilities` are not Android Settings commitments; `sourceControl` is not copied as a row, while the underlying Git and Skills/MCP capabilities remain planned in their real stages.

No statement in this matrix is a claim of full Settings parity, G02 completion or release readiness. The matrix exists to make the remaining work and evidence boundaries explicit.

## 7. Settings-domain P0 additive coverage (candidate only, not implemented)

2026-10-19: Main accepted the rev3 Settings-domain contract and its additive
ledger/fixture mapping. The accepted **P0 source candidate** appends 27 v3
matrix entries under five configuration labels (`settings.defaults`, `memory`,
`personalization`, `usage`, `privacy`) and records ten explicit `SET`-family
operations, all goal **G02** and status **planned**:

| Operation ID | Wire commands | Work packages | Fixture group |
| --- | --- | --- | --- |
| `SET-DEFAULTS-TYPED` | `config.defaults.get`, `config.defaults.save` | P2.2, P2.13 | `settings/defaults-cas.json` |
| `SET-MEMORY-INVENTORY` | `memory.list`, `memory.get`, `memory.add`, `memory.update`, `memory.delete`, `memory.delete.bulk` | P1.2, P2.13 | `memory/inventory.json` |
| `SET-MEMORY-SEARCH` | `memory.search` | P1.2 | `memory/inventory.json` |
| `SET-MEMORY-CANDIDATE-REVIEW` | `memory.candidates.list`, `memory.candidate.resolve` | P2.3 | `memory/candidates.json` |
| `SET-MEMORY-ORGANIZE` | `memory.organize.start`, `memory.organize.proposal.read`, `memory.organize.apply`, `memory.organize.cancel` | P2.3, P2.13 | `memory/organizer-model-output.json` |
| `SET-PERSONALIZATION-DOCUMENTS` | `personalization.get`, `personalization.revision.read`, `personalization.save`, `personalization.rollback`, `personalization.automatic.set`, `content.read` (personalization label) | P1.2, P2.13 | `personalization/documents.json` |
| `SET-PERSONALIZATION-GENERATE` | `personalization.generate`, `personalization.generate.cancel` | P2.2, P2.3 | `personalization/documents.json` |
| `SET-USAGE-AGGREGATE` | `usage.statistics.get` | P1.2, P2.2 | `usage/aggregates.json` |
| `SET-HISTORY-CLEAR` | `privacy.summary.get`, `privacy.history.clear` | P2.7 | `privacy/identity-streams.json` |
| `SET-MODELCFG-CLEAR` | `privacy.modelConfiguration.clear` | P2.7 | `privacy/identity-streams.json` |

Candidate counts were 182 operations / 40 G02 / 33 synthetic fixtures / 36
families / 85 work packages; the goal-core code batch (2026-10-21) appends
ONE explicit operation (`CHA-MANUAL-COMPACT`, G02) and THREE additive bridge
tuples (`plan.accept`, `goal.confirm`, `conversation.compact`), giving
183 / 41 / 33 / 36 / 85 with the matrix at 87 tuples / 85 distinct commands
(57 legacy + 27 settings + 3 run-control; no `child.create`; mailbox bounds
unchanged). The live tree remains 172 / 30 / 26 / 36 / 85 until
Main publishes and integrates the candidate. Adding a vocabulary/wire entry does
not create a handler, store, capability or runtime behavior: a command without
an installed real domain still terminates at the typed `runtimeUnavailable`
seam in this source (the three new tuples have REAL candidate handler sources
in the run domain after the goal-core batch, but nothing is compiled,
installed, executed or device-qualified by source alone). The P1–P8
facade packages and the serialized qualifier must implement and verify the real
original-DB behavior before any row above moves beyond `planned`.


### 7.1 Final rev3 alignment (2026-10-19, source-only)

The final accepted rev3 contract is `contract.json` SHA-256
`f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c`. The P0
candidate was rechecked against that exact file; the 57 legacy matrix tuples
and 14 legacy labels remain unchanged, and the additive delta remains 27
entries / 5 labels.

Final wire-owned clarifications are recorded so later packages do not drift:

- `memory.search` returns a flat `current: MemoryEntryDTO` (never
  `current.entry`) and `current.revision` is the CAS token. The bounded
  `searchHandle` stores only the recall ranking; every page, including the
  first, performs a fresh batched original-DB read for that page's ids, and a
  later page never replays recall or reinforcement.
- `content.read` for personalization is the third matrix entry on the existing
  `v3.command.applicationConfiguration.content.read` handler key; dispatch is
  by `configurationScope` (`conversations | personalization`), while the
  `conversationLifecycle/content.read` key stays separate. P0 adds the matrix
  entry only; P3 registers the real handler.
- `memory.list` uses wire default 50 (the original native method defaults to
  100); both are recorded explicitly and the native 1..500 clamp is preserved.
- Provider secrets are represented only by an opaque `secret_ref_account`
  reference and a `Bool?` `secret_ref_synchronizable` flag. The separate
  `credential_records` vault is excluded from the model-configuration digest.
  A clear operation must detect a reference change outside and inside the
  writer after the gateway await.
- Content sizes are actual UTF-8 bytes. Inline personalization content is
  emitted only when the complete encoded response (metadata + content + JSON
  escaping) fits 48 KiB; otherwise an owned handle and `content.read` chunks
  are used. The 64 KiB frame bound is retained and there is no extra 16 KiB
  inline cap.
- The memory-delete tombstone's wall-clock `sync_revision` is an ordering
  value, never a CAS precondition. No original store actor method may be
  awaited inside a `DatabaseManager.writer/reader` closure.

These remain design/source facts. No handler, capability, build, test run,
device result, G02 completion or release is claimed here.
