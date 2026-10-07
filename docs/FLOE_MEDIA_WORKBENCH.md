# Floe 媒体工作台 / Media Workbench (1.7.23, build 264)

Status: **current implementation reference** (2026-10-07, uncommitted workbench branch).
Applies to the unified image/video workbench introduced in 1.7.23. Previous
single-asset editors remain available as compatibility paths
(`FloeImageEditorView`, `MediaEditorView`) but every main entrance now opens
the workbench.

## 1. 架构 / Architecture

| Layer | Location | Responsibility |
| --- | --- | --- |
| Versioned project model | `FloeAgent/Sources/FloeWorkbench/MediaProjectModel.swift` | `MediaProject` (schema v1, stable UUID, monotonic `revision`), external `MediaAssetReference`s, image layers, video timeline (clips / music / captions / transitions), export options, preserved unknown operations, durable undo/redo mementos |
| Transaction engine | `MediaTransactions.swift`, `MediaEditCommands.swift` | Shared validated edit commands. Draft-then-commit: a rejected command in a sequence leaves the document untouched. Undo/redo always advances the revision (never restores an old number), so stale proposals cannot alias |
| Persistence | `MediaProjectStore.swift` | Atomic JSON save with revision compare-and-swap; projects under Application Support `FloeAgent/MediaProjects`; durable undo history travels with the document |
| Migration | `MigrationSupport.swift` | Legacy single-asset parameter plans migrate; unknown operations are preserved verbatim and reported, never dropped |
| Image renderer | `WorkbenchImageRenderer.swift` | Non-destructive Core Image compositing: layers (image/text/freehand), transforms, opacity, crop, mosaic/filters/basic color; EXIF orientation applied on decode; downsampled preview; full-resolution guarded export; PNG/JPEG/HEIC with explicit dimensions/quality/transparency/metadata and invalid-combination validation |
| Video renderer | `WorkbenchVideoRenderer.swift` | One primary track (per-clip trim/speed/volume/mute/rotation/crop, hard cut + cross dissolve), one music track (offset/trim/length/volume/fades mixed with original audio), burned captions, unified canvas aspect-fit, explicit fps/resolution/H.264/HEVC, staged + verified + atomic output, cancellation with no misleading success file |
| Live preview | `WorkbenchVideoRenderer.renderPreview` | Renders a lightweight H.264 proxy through the SAME export pipeline and plays the file: transforms, crop, dissolves, burned captions and the audio mix are by construction the export frames. A live `AVVideoComposition` on `AVPlayerItem` is not used because the iOS 27 playback pipeline refuses to prepare composition items attached to `AVPlayerLayer` (AVFoundation −11800 / OSStatus −12784) even though the identical composition exports and plays headless |
| Proposals + grants | `MediaProposal.swift`, `MediaProposalGrantStore.swift` | AI proposals bind the exact revision; UI preview, user acceptance mints a single-use, expiring, revision-bound grant. The tool can never bypass confirmation and stale proposals are refused after any manual change (including undo) |
| Tool | `MediaProjectTool.swift` | `media.project` with `read` / `propose` / `apply` / `export` |
| App service + UI | `FloeApp/Workbench/` | `WorkbenchCenter` (store, renderers, grants, proposals, candidates, durable jobs; also the `MediaProjectHost`), adaptive layout, image/video panels, AI drawer |
| Entrances | `FloeApp/Files/FilesView.swift`, `FloeApp/Workspace/FilePreviewView.swift`, `FloeApp/Workspace/WorkspaceCanvasView.swift` | Files tab (image + video), workspace preview (write-back through the digest-checked commit), Canvas (derived asset via the existing ingestion path) |

## 2. Layout and interaction

- Wide landscape iPad: assets/layers left, large preview center, properties
  right, video timeline bottom. The three-column layout requires genuinely
  wide bounds (`width ≥ 1180pt` and clearly landscape); portrait iPad, narrow
  split views and iPhone use the drawer layout so the preview is never
  squeezed into a strip, with the timeline kept at the bottom and all controls
  ≥ 44pt.
- The custom editing session (selection, playhead, zoom, crop mode, fullscreen)
  lives in `WorkbenchCenter`; fullscreen and panel collapse never reset the
  editing session, and one player model is reused for the whole session.
  Source compare renders the untouched first source layer (including its
  opacity reset to the true original). A failed preview item is detected and
  rebuilt (player + proxy) before an actionable error is shown.
- Saved projects: the workbench toolbar lists saved projects scoped to the
  current owner/environment/workspace and opens them through
  `WorkbenchCenter.openProject`, which keeps the project's recorded asset root
  even when another workspace is open. Opening a source that already has a
  saved project offers resume-or-fresh instead of silently starting over.
- Image edits: interactive crop (drag + corner handles), move/scale/rotate
  gestures, layer reorder (drag), hide/lock/opacity, text/freehand layers,
  adjustments (saturation/contrast/brightness/exposure/blur/sharpen/mosaic)
  and the deterministic built-in filter set. Oversized sources create an
  explicit scaled working copy (with a recovery notice) instead of forcing a
  full decode; missing assets show a relink action that preserves all edits.
- Video edits: thumbnail timeline with drag reorder, playhead scrubbing and
  zoom, split at playhead, per-clip inspector (trim/speed/volume/mute/rotation/
  crop/transition), music track (offset, source trim start, audible length,
  volume, fades) and caption tracks, and transcription through the existing
  local `FileSpeechTranscriber` (segments are retimed through clip speed onto
  the unified timeline).

## 3. `media.project` tool contract

Actions and effects:

| Action | Effect | Notes |
| --- | --- | --- |
| `read` | read-only | Project summary: revision, canvas, assets, layers/clips/warnings |
| `propose` | internal draft | Validates every command against a draft, stores a revision-bound proposal, returns preview, `requiresUserAction = true` |
| `apply` | mutating | Requires `proposal_id` + UI-minted `grant_id`; the host validates and consumes the single-use grant; applies one undoable transaction with revision CAS |
| `export` | mutating | Image/video export through the same guarded renderers |

Ownership: every action first calls `MediaProjectHost.authorizeAccess`. A
project that records an environment, task workspace or task-scoped owner
(chat/canvas) requires the caller to present the SAME context — absent context
is refused, never treated as a wildcard — and a standalone project is not
reachable from a workspace-scoped caller. The full command schema
(command names and required fields) is embedded in the tool's
`parametersJSON` so the model can construct commands without external docs.

Confirmation flow: the model prepares a proposal → the workbench AI drawer
shows it → the user taps accept. The shipped UI applies the confirmed proposal
itself as one undoable transaction (the trusted interactive path); the tool's
`apply` action is a second, grant-gated path used by hosts that mint grants via
`MediaProposalGrantStore.issueGrant` after user acceptance. A fabricated grant
id, an expired grant, a consumed grant, a revision mismatch or any manual edit
(including undo/redo) makes tool apply fail with an explicit reason. Either way
the model can never apply a proposal without user confirmation.

## 4. AI behavior

- Reuses only enabled, adapter-backed image providers (via
  `ConversationCenter`) and the durable video job infrastructure
  (`video.models` / `generate` / `status` / `cancel` semantics through
  `MediaGenerationService`). No new provider integrations; no automatic
  provider switching.
- The pre-submission review is a typed immutable request. The confirmed
  submission is exactly what the sheet showed: an image edit keeps its source
  asset reference, size and count; a video job keeps its duration, aspect
  ratio and resolution. (Previously both were silently discarded as nil.)
- The pre-submission review shows model, uploaded assets, parameters and an
  honest cost note (provider account is authoritative; Floe never invents
  prices).
- Candidates never replace the project: they must be accepted and are then
  imported as a new layer/clip. Delivered image candidates and durable video
  jobs are recorded per project and survive closing/reopening the workbench;
  stale records whose file disappeared are dropped rather than shown.
- Jobs survive closing the view (durable store keyed by the project id).
  “Stop waiting” only stops local refresh; “Cancel remote job” asks the
  provider to cancel. Unknown submissions are never auto-resubmitted: recovery
  lists the existing durable job instead of resubmitting. Each explicit user
  submission is its own durable job.
- Image generation has no provider job id to poll, so a confirmed request is
  persisted before the call and given a truthful terminal classification:
  delivered candidates retire the record; a definitive provider rejection is
  `failed`; a timeout/transport error after submission is `unknown` and a
  process death/cancellation mid-call is `interrupted`. Unknown/interrupted
  records are restored on reopen and never retried automatically. A confirmed
  review (image or video) can never be submitted twice.
- Delivered image candidates are persisted against the project the review was
  confirmed against, frozen before the await: switching projects while the
  call is in flight never attaches the result (or the request record) to the
  visible project; reopening the original project shows it.

## 4b. Export delivery and ownership

- A verified export (image or video) is retained on `WorkbenchCenter
  .lastExportResult` with its file URL. The export panel shows the result with
  a native URL-based `UIActivityViewController` (Share / Save to Files /
  AirDrop); the movie is streamed by URL and never read into memory.
- The entrance `onExported` callback fires **exactly once per workbench
  presentation** and only for a verified successful export (failure and
  cancellation never fire it). It is registered when the export panel appears
  and cleared when the workbench closes (`closeProject`), so closing just the
  drawer during an export does not drop the entrance delivery.
- Every new attempt, pre-flight validation failure, render failure,
  cancellation and project open/start clears the retained result first, so a
  stale success can never remain shareable. Cancellation is shown as a neutral
  notice, not a green success.
- The media root is frozen for the whole export before the first await
  (`WorkbenchVideoRenderer.export(..., mediaRoot:)`); later clips and music
  resolve against the original project's root even if the user opens another
  project mid-export. A stale late completion publishes nothing and never
  deletes a previous valid output (the atomic commit only replaces the
  attempt's own path).
- A workspace file preview opened from a chat task records `chat` ownership
  with that conversation id (and the workspace path); a genuinely
  workspace-only preview keeps `workspace` ownership. No environment id is
  invented — the conversation model carries none — and the task-scoped gate
  still refuses another conversation and workspace-only callers.

## 5. Verification (what was actually run)

- `swift build --target FloeWorkbench` (macOS host, Xcode 27 toolchain):
  passed.
- `FloeWorkbenchTests` (46 tests, run via `xcrun xctest` on the built bundle):
  **46/46 passed**. Covers layer order/undo/redo monotonicity/durable
  reopen/failed sequence atomicity/CAS/migration with unknown ops/relink/no-op
  rejection; proposal staleness, grant single-use/expiry/revision mismatch,
  ownership refusal with absent and mismatched context, unknown commands,
  unavailable export; EXIF orientation, transparency vs JPEG rejection,
  Chinese text rendering, explicit-dimension export verification,
  determinism, big-image guard; real synthesized video for mixed
  orientation/fps normalization, per-clip trim+speed, cross-dissolve
  duration contraction and rendered dissolve blending, music mix with
  audio/video sync, caption burn-in and caption overrun validation,
  cancellation without output, failure preserving the existing output,
  path-escape rejection; and the preview proxy itself (ready-to-play item,
  decoded red/blue frames, burned captions, rotated orientation + crop,
  dissolve ramp, audio track + fade-out ramp, preview/export frame agreement,
  and a thrown error instead of a blank item for missing assets).
- `FloeAppTests/WorkbenchAIReviewTests` (4 tests, Xcode 27 iOS 27 simulator,
  iPad Air 13-inch M4): **4/4 passed** — confirmed image edit keeps reviewed
  source/size/count (and candidates survive reopen), confirmed video job keeps
  reviewed duration/aspect/resolution, `authorizeAccess` refuses absent or
  mismatched context, and a saved project is found, resumed and still carries
  its edit, owner kind and asset root.
- `FloeAppTests/WorkbenchExportDeliveryTests` (15 tests, same simulator):
  **15/15 passed** (`logs/app-tests-export-delivery.log`). Image + video
  verified exports retain the result URL and fire the entrance callback exactly
  once per presentation (a second export updates the result but does not call
  back; re-registration re-arms once); failure, invalid options, cancellation,
  `clearExportDelivery` and project switch all clear the stale result and never
  call back; an in-flight image generation switched to another project
  delivers/persists its candidate to the original project only; duplicate image
  and video confirmations submit once; timeout → `unknown`, definitive
  rejection → `failed`, cancellation → `interrupted`, and an abandoned
  `.submitted` record is restored as `interrupted`; the same chat task passes
  `media.project` authorization while another conversation, a workspace-only
  caller and another workspace are refused.
- Full App compile: Xcode 27 `build-for-testing` (app + `FloeAppTests` +
  `FloeAgentUITests` bundles),
  `-destination 'generic/platform=iOS Simulator'`, 6 jobs: **TEST BUILD
  SUCCEEDED** (`Local/Private/build264-media/logs/app-build-final.log`). Earlier
  device slice (`generic/platform=iOS`, unsigned) also **BUILD SUCCEEDED**;
  recoverable artifact preserved at
  `Local/Artifacts/build264-media/FloeAgent-1.7.23-264-unsigned-device-validation.zip`
  (sha256 `2306ad2c6a7f4ab370eb33e403500d1707ad1c9f508d2fed2145ecd61f12dc38`,
  uncommitted validation artifact — not signed, not uploaded, and predating
  the preview/layout repairs).
- UI fixture hook: launching with `-ui-testing --ui-test-workbench-fixture`
  synthesizes an image, landscape+portrait videos (different frame rates) and a
  music track, and opens the video workbench on them. On the iPad Air
  13-inch (M4) simulator with `--ui-test-workbench-video
  --ui-test-workbench-preview-probe`, the probe recorded the rendered preview
  proxy: `itemStatus = 1` (readyToPlay), `playbackAdvanced = true`,
  `currentTime = 1.90s`, `frameNonBlack = true` (average colour 0.318).
  Evidence screenshot: `Local/Private/build264-media/evidence/sim-video-preview-fixed.png`.
- Layout: portrait iPad Air 13-inch (M4) simulator now uses the drawer layout
  with a large preview and the bottom timeline; all four drawer controls and
  the toolbar (including the Projects entry) are fully visible
  (`Local/Private/build264-media/evidence/sim-portrait-compact.png`).

Primary UI acceptance (earlier pass) found and this branch fixed: stale slider
values after undo and double undo steps per drag (CommitSlider now resyncs on
external change, cancels pending local commits and commits exactly once per
gesture), silent failures (alert presentation plus a preview error overlay
with Retry), the video fixture opening blank, the video preview staying black
with an inert play button (rendered proxy + session-owned player + item
failure recovery), AI review parameters being discarded, missing music
length/trim controls, sub-44pt delete buttons, the nil-context ownership
bypass, the original-compare opacity leak, separate per-presentation players,
portrait layout squeezing the preview, and the missing project reopen entry.

Not yet verified (honest gaps):

- Physical-device rendering/playback and hardware encoders; the preview-proxy
  behavior was verified on the iOS 27 simulator only.
- Real cloud image/video generations (no paid provider calls were made).
- HDR/wide-color output beyond the simulator compile.
- Signed/packaged release, TestFlight processing and the public test group.
- The full `FloeAgentUITests` UI-test bundle was compiled but not executed;
  module tests plus `FloeAppTests` are the executed behavioral evidence.

## 6. Notable implementation decisions

- The workbench renderer implements its own Core Image chain rather than
  calling `FloeImages.ImagePipeline` per operation, because layer
  transforms/crops must compose with adjustments in one pass; the
  deterministic adjustment vocabulary (saturation/contrast/brightness/
  exposure/blur/sharpen/mosaic) is shared. Video export likewise uses its own
  reader/writer path instead of `MediaTranscodePipeline`, because a custom
  compositor is required for dissolves, aspect-fit and caption burn-in. The
  same compositor renders the preview proxy, so preview and export cannot
  diverge.
- Playback deliberately uses a rendered proxy: the playback pipeline cannot
  receive a custom instruction subclass (it snapshots instructions to the
  immutable base class), and on iOS 27 an `AVPlayerLayer` fails to prepare
  items carrying any `AVVideoComposition` at all (−11800 / −12784). Rendering
  through the proven export pipeline and playing the file keeps one renderer,
  identical output on device and simulator, and no playback-time composition
  state to lose.

- Dissolve semantics contract the timeline like a non-linear editor
  (`MediaTimelineMath.placeClips`); captions, music, playhead and export
  verification all use that single time base.
- Each clip gets its own composition track pair, which keeps per-clip trim,
  speed and dissolve overlaps exact while bounding the clip count.
- Image layers store bottom-first; the UI presents them top-first.
- Locked layers refuse geometry/content edits but still allow opacity.
