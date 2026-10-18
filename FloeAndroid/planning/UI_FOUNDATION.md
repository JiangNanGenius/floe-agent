# Floe Android G01 — UI foundation contract (2026-10-18)

Task: `job-e8b01ad287f84a89` · Supersedes the rejected sparse Material shell.
This file is the durable contract for the foundation visual structure. It is
**G01 foundation only**: it does not mark G01 complete and claims no product
parity. The independent second finish-review verdict is **SHIP for the original
seven findings at representative native UI/component-foundation scope only**.
Goal-state closure and later product acceptance remain with the coordinator.

## Direction (pinned by the user brief, not a new identity exercise)

The Android shell reproduces the **current installed Floe iPad UI** —
structure, proportions, density and copy measured from
`captured iPad reference screenshots (private evidence retained outside the repository)` (Floe 1.7.34
(275), canonical iPad mini, source-freshness verified) and re-read live from
`FloeAgent/FloeApp` at the receipt base. Substrate decision is frozen by the
verified prerequisites (no reopening): **compose-cupertino (RobinPcrd fork)
3.3.1 explicit components + Floe token bridge + one custom three-pane
shell**; SkipUI stays rejected; `cupertino-adaptive` and
`cupertino-icons-extended` are intentionally not consumable coordinates.
iOS-visual brief overrides generic Android Material-everywhere advice;
platform obligations kept instead: 48dp targets, real system back, window
insets/IME, semantics, sp type, no dynamic wallpaper colors.

## Structure mirrored from iOS sources (code-verified line ranges)

| Surface | iOS source | Android implementation |
| --- | --- | --- |
| Stable 2 columns + on-demand inspector inside detail | `FloeAgentApp.swift` L814-848 | `FloeShell` persistent Row (sidebar / divider / content + optional inspector lane); inspector recreated per route identity |
| Sidebar widths 260/320/460 | `FloeAgent/Sources/FloeCore/LayoutDisplay.swift` L115-117 | `FloeLayout.SidebarMin/Ideal/MaxWidth` |
| Inspector widths 360/430/520 | L841 | `FloeLayout.InspectorMin/Ideal/MaxWidth` |
| Compact drawer `min(390,max(300,w-44))`, 28 corners, scrim, edge open | `iPhoneRoot` L701-744 | `FloeShell` drawer branch + `FloeLayout.drawerWidth` |
| Fixed 5 routes New Task/Task Center/Notes/Creative/Plugins + workspace/chat sections + footer gear (settings = sheet) | `sidebarContent` L869-972 | `FloeSidebar` + `fixedSidebarRoutes` order (unit-tested) |
| Row components: workspace (folder + plus + chevron) & conversation (bubble + badge) | `conversationSidebarRow` L1046-1095 | `FloeWorkspaceRow`/`FloeConversationRow` (used only by labelled debug preview with synthetic data) |
| Home launchpad: centered hero icon 76/r18 + welcome, bottom composer safe-area inset, max width 720 | `HomeLaunchpadView.swift` | `HomeLaunchpadPage` |
| Composer r22 continuous, 0.5 separator stroke, h12/v8, paperclip/field/mic/send, chip row model→reasoning→project→target→mode→permissions; chrome capped and centred at 720dp on wide windows; whole composer above the gesture/navigation bar and IME | `ThreadComposerView.swift` L293-301, 779-1090 | `FloeComposer` (+ `ComposerSendPolicy` unit tests); `FloeLayout.ComposerMaxWidth`, `safeDrawing` bottom inset |
| User bubble r12 accent@14% h12/v8; tool card; amber approval card; monospaced evidence | `UserMessageBubble.swift`, `ThreadEventView` family | `FloeThreadComponents.kt`, exercised by debug `ComponentPreviewScreen` with synthetic fixtures only |
| Settings sheet with own two-column navigation (wide) / stack (compact) + Done | `SettingsRootView.swift` L75-136 + 03-settings capture | `SettingsSheet` in `FloePageSheet`: 76dp top inset, 320dp section column owning title/Done/column toggle, independent 34sp detail title with 68dp top padding, slide-up rounded surface, scrim, back-to-close |
| ContentUnavailableView analog | iOS empty-state call sites | `FloeUnavailableView` |

Selection capsule: BLUE for the active New-Task row (capture 01) and GRAY for
secondary selections (capture 02 focus variation), both true capsules
(`FloeLayout.SidebarSelectionShape`); the exact two grays/blues are sampled
values documented in `FloeColors.kt` (accent #0081F6 light / #0A84FF dark —
system blue per coordinator precision note; brand ramp kept separate and used
only where iOS uses gradient semantics). The footer/General settings glyph is
a source-authored eight-tooth gear outline, not the earlier ray/sun form.

## Reusable tokens and component vocabulary (finished foundation)

The normative Android values remain in `core/designsystem/.../FloeColors.kt`,
`FloeType.kt` and `FloeLayout.kt`; this contract records their incumbent mapping,
not a new root design system. `FloeTheme` bridges those roles into explicit
`CupertinoTheme` light/dark schemes. Root `PRODUCT.md` and `DESIGN.md` remain
unchanged context; no `.impeccable` sidecar or identity refresh is required for
this ordinary platform extension.

| Reused role | Current Android value / behavior | Incumbent basis |
| --- | --- | --- |
| Interactive accent | Light `#0081F6`; dark `#0A84FF`; pressed `#0071D9` / `#409CFF` | Captured iPad navigation blue; `.accentColor`, separate from the brand ramp |
| Brand identity ramp | Cyan `#1AC7DB` → blue `#3D7AF5` → violet `#8F5CF0` | `FloeTheme.swift` brand stops; hero/identity and explicit gradient semantics only |
| Decision / failure / success | Light `#FF9500` / `#FF3B30` / `#34C759`; dark `#FF9F0A` / `#FF453A` / `#30D158` | iOS orange/red/green roles; success requires confirmed success |
| Reading / sidebar / grouped / section card / chrome planes | Light `#FFFFFF` / `#E6EAEE` / `#F2F2F7` / `#FFFFFF` / `#F6F6F7`; dark `#000000` / `#1C1C1E` / `#1C1C1E` / `#2C2C2E` / `#1C1C1E` | Opaque reading plane plus sampled navigation and grouped surfaces |
| Text, separators and tint fills | Primary black/white; secondary and tertiary iOS-style alpha labels; separator/chrome hairlines; accent approximately 9% for mic fill and 14% for user bubble | `FloeColors` semantic roles; do not replace with wallpaper-derived colors |
| Type hierarchy | Title 22/28sp semibold; section/toolbar 17/22sp semibold; body/composer 17/24sp regular; emphasized body 17/24sp medium; large navigation title 34/41sp bold; metadata/group/evidence 13/18sp, evidence monospaced | `FloeTheme.Typography` title2/headline/body/footnote roles plus iOS settings large title; platform sans uses `sp` |
| Shared geometry | Composer r22, bubble/tool r12, card/hero r18, drawer r28, settings sheet r24; capsule selections/chips; 0.5dp hairlines; composer h12/v8 inner and outer padding | Incumbent form language with Android `dp` geometry; rounded corners approximate iOS continuous corners |
| Controls | Toolbar 44dp visual circle, composer 34dp visual circle, chip 32dp visual pill; all own at least 48dp actual targets; sidebar rows 48dp, outline icons 24dp | Keep iPad density while meeting the Android interaction floor |

Common controls are Floe wrappers, not page-specific replacement designs:
`FloeCircleButton`, `FloeSidebarRow`, grouped sections/rows, segmented theme
selection, field/dropdown/alert, `FloeComposerChip`, and the independent
`FloeSelectionSlot`. `FloeThreadComponents` supplies the user bubble,
assistant reading text, expandable tool/evidence card and amber approval card.
The debug component preview is labelled synthetic; it is not live history or
working task execution. Status remains readable through text/icons as well as
color. The source-authored outline icon family keeps semantic meaning without
redistributing SF Symbols or fonts.

Depth comes from opaque tonal planes, hairlines and overlay scrims (drawer
22%, inspector 18%, sheet 28%), rather than a new elevated-card language.
iOS bar material and composer shadow are approximated by opaque Android chrome;
there is no claimed native blur or exact spring/material equivalence.

## Responsive contract (coordinator guidance, 2026-10-18)

- Persistent two columns from **600dp actual usable width** (iPad mini
  portrait 744pt keeps its sidebar — no 840dp phone-drawer cutoff).
- User collapse: toolbar toggle collapses the persistent sidebar into the
  overlay drawer; expansion restores it.
- When sidebar+content+inspector minimums cannot all fit (total <
  `FloeLayout.InspectorOverlayMaxTotalWidth`), the inspector becomes a
  trailing **overlay** with scrim instead of squeezing content to near zero
  (local adaptation, recorded here).
- System back order: the preview closes its own inspector before leaving the
  preview; otherwise settings sheet (and in-sheet compact detail) → inspector
  → drawer → non-home route back to New Task;
  at New-Task root with nothing open, back delegates to the platform.
- Bottom insets: the composer consumes `WindowInsets.safeDrawing` at the
  bottom, so the closed-gesture-bar and IME cases both lift the complete
  bordered chrome (never an inner padding that grows the background). The chip
  row is part of that chrome and stays visible.
- Actual targets: every toolbar circle, composer control and context chip owns
  the ≥48dp clickable/semantics box; the toolbar circle is 44dp, composer
  circle 34dp and chip pill 32dp visually. Tool-card selection uses an
  independent 48dp checkbox slot outside the expander row.

## Substrate & dependency policy

- `io.github.robinpcrd:cupertino:3.3.1` consumed only through
  `core/designsystem` (`api(libs.cupertino)`); explicit components:
  `CupertinoTheme`, `CupertinoSection/SectionItem`, `CupertinoSwitch`,
  `CupertinoSegmentedControl`, `CupertinoTextField`, `CupertinoCheckBox`,
  `CupertinoButton`, `CupertinoAlertDialog`, `CupertinoDropdownMenu`.
  No Adaptive APIs; `cupertino-adaptive`/`-icons-extended` absent from the
  graph (verified in `evidence/resolved-*.txt` exports).
- `material-icons-extended` removed from the graph (debug APK
  190.4 MB → 171 MB baseline drop); icons are the source-authored
  `FloeIcons` geometric outline family (no emoji, no SF fonts/symbols).
- Locks/verification updated narrowly: 52 components added to
  `gradle/verification-metadata.xml` (0 removed, per pre/post diff), module
  lockfiles regenerated with `--write-locks`; a `--offline` strict
  verification build passes for all five APK outputs.
- Versions untouched: Gradle 9.6.0 / AGP 9.4.0 / Kotlin 2.2.10 / BOM
  2026.09.00 / compileSdk 37 / minSdk 28; debug keystore pin kept
  (`app/build.gradle.kts` now rejects relative raw paths before resolution;
  the aligned `core/swiftbridge` guard was coordinator-owned).

## Truthful capability state (G01 foundation)

Implemented for real: route/sidebar state, home draft editing (RAM store,
synchronous update), local Day/Night theme setting (persisted), composer
field + IME guard + pure send policy, diagnostics real JNI handshake on the
IO dispatcher, debug-only labelled component preview incl. working sample
selection + inspector sample.
Explicitly NOT offered as working: model/provider configuration and send
(G02), temporary chat lifecycle, attachments/voice, projects/workspaces,
notes/creative/plugins, non-progress inspector contents. Each such surface
displays an honest unavailability statement — no fake success, no imported
device history, and Android's default model state is "cloud unconfigured"
(never the captured iPad's Apple Foundation Model).

## Known local adaptations (measured, not hidden)

- Font metrics: system sans (Roboto) vs SF Pro; `sp` scaling is retained.
- RoundedCornerShape approximates iOS continuous corners; Android target
  geometry is 48dp rather than the iOS 44pt minimum.
- Inspector overlay below 900dp total width preserves readable content; the
  600dp persistent-sidebar threshold uses actual available width.
- Press feedback & section animations come from CupertinoIndication/tweened
  transitions; iOS `.snappy` spring is approximated.
- The gray "focus" capsule variant is a per-row style decision, not true
  first-responder tracking.
- Chrome is opaque sampled color (no platform blur shader) per "glass
  restrained" rule.
- `qa-foundation.py` follows the new gear→sheet→diagnostics flow and expects
  the exact bilingual labels above.

## Finish-review repair batch (2026-10-18, job-2d2a9e1a72ab4039)

Seven findings from the independent first-pass review were repaired and then
reviewed in two bounded verdict passes. Round 1 resolved F01/F02/F03/F06/F07
from 33 phone/tablet captures; round 2 resolved F04/F05 from six targeted
Samsung captures and the matching installed final APK. The same independent
reviewer returned **SHIP**, retaining all seven original IDs as resolved.
This verdict covers the representative foundation only, not whole-product or
G01 evidence closure.

| ID | Change | Source evidence |
| --- | --- | --- |
| F01 | Composer chrome capped/centred at 720dp; `safeDrawing` bottom inset lifts the whole bordered box above gesture bar/IME; CupertinoTextField's intrinsic 280dp minimum is isolated in a weighted slot; mic/send/stop are explicit 48dp targets; chips use a 48dp target around the 32dp pill | `FloeComposer.kt`, `FloeLayout.ComposerMaxWidth/ComposerChip*` |
| F02 | `FloeDetailToolbar` requires `compact`; Task Center and every placeholder route pass it, so the phone drawer opener exists on all four non-home fixed routes | `FloeDetailColumn.kt` |
| F03 | Wide settings: 76dp sheet top inset, 320dp section column with its own title/Done/column toggle, independent detail header at iOS `.largeTitle` (34sp) placed 68dp below the sheet top (measured from 03-settings) with a staged content inset; compact stack unchanged | `SettingsSheet.kt`, `FloeSheet.kt`, `FloeType.kt` |
| F04 | Opening settings clears the compact drawer before raising the settings Dialog (the home section entry clears it too); opening the preview clears the drawer and dismisses the sheet before composing the shell-hosted preview, so Back from the preview reaches the underlying page/home with no stale drawer or sheet. Current Samsung QA and targeted captures verify inspector Back retains preview, then preview Back reaches Home without the old drawer/sheet; the round-1 failure is preserved | `FloeShell.kt` |
| F05 | Toolbar/composer/chip parent owns the ≥48dp target. Samsung density 480dpi gives 144px for 48dp; actual taps at y2189 and y2329 (140px apart, 2px inset from each edge) both open the same Model/Provider detail. The clipped 30dp UIAutomator label bounds are not the parent hit bounds | `FloePrimitives.kt`, `FloeComposer.kt`; round-2 behavior report and six-capture packet |
| F06 | Independent 48dp Cupertino checkbox slot outside the tool-card expander row; full glyph unchecked/selected | `FloeThreadComponents.kt`, `FloePrimitives.kt` |
| F07 | Sidebar selections use a capsule; the footer/General gear is a source-authored eight-tooth outline instead of the ray/sun glyph | `FloePrimitives.kt`, `FloeIcons.kt` |

Touched theme copy now says "system appearance settings" /
"系统外观设置" instead of the iOS-only "显示与亮度" path. No new settings
link or backend was added. `qa-foundation.py` now checks the compact drawer
opener on all four non-home routes, one-tap preview visibility and preview
Back, keeping system Back only for the drawer/sheet dismissal steps.

## Verification (observed evidence, 2026-10-18)

- **Exact build record:** `the G01 final build handoff record (private evidence retained outside the repository)` records base commit
  `4ec0405a532ac84d964d8fb6fbebaea666d02d74`, exact working-tree source
  snapshot `aaacd262db417f9c550da79918d36363de89412b7934d1fd2596370cea55f67b`
  (not a release tag), JDK 21.0.12.1, Gradle 9.6.0, and the explicit offline
  strict-verification command. Both app flavors and all three test APKs
  assembled; 30/30 APK checks passed, signer identical across all five;
  native manifest remains 29 libraries / 4 shared sources / 7 native inputs.
  Final full APK SHA-256:
  `a3dff8f5ea58a53ac22a80c98ee273f02e8e9efd5c8679fd8140d2ce3c5ebf1f`;
  play APK: `b7dad6d3d05a0cad8790a04b0c9bf656bdab38ebaf2acf3c38e489846f4a31c8`.
  Exports: `the retained G01 final build artifacts (private evidence retained outside the repository)`.
- **Reused checks, not rerun claims:** the prior UI batch passed 9/9
  design-system unit tests. `the retained G01 device test records (private evidence retained outside the repository)`
  records 3 JNI + 1 full + 1 play instrumented tests passing on each target
  (Samsung API33 and tablet API37). The final batch changes only shell drawer
  flags at runtime: app DEX differs, native libraries/resources are unchanged,
  and all three test APKs are byte-identical. The tests were not rerun for the
  flag-only correction.
- **Current Samsung behavior:** `the retained G01 Samsung smoke record (private evidence retained outside the repository)`
  passes all four non-home route openers, one-tap preview, preview Back to Home,
  sheet Back, real Swift JNI handshake and relaunch. Its installed `base.apk`
  SHA matches the final full APK above. Installation used **`install -r` with
  retained app data**, then force-stopped the owned package; no clean-install
  acceptance is claimed.
- **Tablet and rendered coverage:** prior `the retained G01 tablet smoke record (private evidence retained outside the repository)`
  passed all routes, one-tap preview, Back/Home, sheet dismissal and real JNI on
  the prior UI batch APK (`80e3e6acc00fd971b053b87d591ef958e84bcaf0ed7a7f2d19bbadd927deb7cb`).
  Tablet was not rerun on the final flag-only APK. The retained 33 screenshots
  cover phone, tablet landscape/portrait, dark appearance, larger text,
  selection/expansion, inspector, draft/IME and visible bottom insets; six
  final Samsung captures close only F04/F05. Compare logical dp/pt proportions:
  Samsung 360dp wide, tablet 1280×800dp / 800×1280dp, iPad 744×1133pt /
  1133×744pt. Screenshots are native evidence, not generated mockups.
- **Independent review:**
  `the round-1 independent review verdict (private evidence retained outside the repository)`
  preserves the F04/F05 partials; `the round-2 independent review verdict (private evidence retained outside the repository)` records
  all F01–F07 resolved and disposition `ship`. The round-2 packet points to
  source, installed SHA, QA, actual edge touches and the six captures.
- **Limits:** these records do not establish full product parity, complete
  TalkBack, complete CJK IME behavior, or 16KB runtime qualification (recorded
  QA page size is 4096). Phone draft/disabled-send/navigation and tablet
  rotation assertions establish only their recorded cases. No model execution,
  durable conversation storage, or later-goal functionality is inferred.

Evidence references above denote private project records retained outside the repository
unless an explicit repository path is given. The archived build snapshot
contains the earlier contract wording; this post-review documentation refresh
changes no runtime source or artifact identity. Its source/hash checks are
recorded separately in `the private documentation-closure report`.

## Handoff to G02+

Thread/preview components and `ComposerSendPolicy`/`FloeDraftStore` are the
binding points: live state replaces fixtures without layout replacement.
Keep Floe tokens, wrappers, the stable shell and native interaction obligations
when wiring later goals. Durable drafts, temporary-session lifecycle, model /
provider persistence, real send, Notes, Creative and Plugins stay at their
planned goals and retain truthful unavailable states until connected and
verified. Do not copy captured iPad history or settings into live Android data.
The representative foundation verdict does not advance a goal ledger by itself.
