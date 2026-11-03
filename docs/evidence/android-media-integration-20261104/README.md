# Android media integration checkpoint — 2026-11-04

This is a source checkpoint, not an installable delivery or a claim of full application acceptance.

- iOS behavior reference: `36f63bf400dfaa3a127259eac006b38d72516390`. Existing feature and gap IDs remain unchanged.
- Model-facing image/video tools now connect to the original generation adapters, durable job records, task-owned workspace delivery, shared worker lifecycle and cancellation. Dispatch intent and accepted handles survive unknown outcomes; work is not silently replayed.
- Media enhancement adds task-Linux FFmpeg interpolation, measured source/output contracts, a configurable cloud super-resolution backend and editor/settings entry points. No local AI model or plain-resize substitution is introduced.
- Enhancer credentials use the original sealed secure ingress, native vault ownership and immutable credential rotation. Business JSON carries an opaque one-use intent, never secret bytes.
- Integration repairs cover Android-supported bounded HTTP streaming, actual upload bodies, awaited progress, serialized journal updates, bounded worker admission, input lifetime and staged output publication that preserves existing files on precommit failure.
- Provider navigation uses a compact title after scrolling. Android-specific system permission and installation UI remains native.

## Verification boundary

Swift 6 ARM64 release object compilation passed before the final interpolation/publication lifecycle corrections. An ARM64 production link and signed candidate package passed before a subsequently detected journal timestamp precision defect. The corrected journal preserves exact Date precision, reads predecessor records and requires a new final candidate; the earlier APK is retained as intermediate evidence. Full/Play application and runtime Kotlin compilation passed. Focused JVM contracts passed (27 tests, zero failures); these cover the enhancer host, provider catalog and enhancement value contracts. 32 focused media contract, probe, backend-origin and journal tests passed in a macOS component host using the production sources and original value declarations. These include concurrent handle/progress updates, legacy ISO8601 date compatibility, exact timestamp round trips and failed-write preservation. Full task/vault Swift service tests and Android runtime behavior remain separate pending gates.

Final production libraries, signed APK, Samsung/tablet acceptance, actual provider calls and full/delta upgrade installation remain separate pending gates. Public Android Alpha22 and the iOS Latest pointer are unchanged.

## Real-provider test routing

Use the existing Ark Plan configuration with `ark-code-latest` for LLM testing and its configured image route. Video generation uses the separately authorized Volcengine pay-as-you-go route because this test account's plan excludes video. This does not disable configured plan routes for other accounts. Perform one minimum supported request per media scenario, stop on failure or unknown acceptance, and do not automatically resubmit or switch paid providers. A successful model-list response is not proof of working generation.

## Cold-start follow-up

The first installed candidate exposed eager font-pump creation before the RuntimeHost factory injected its Android Context. Font startup now follows the existing context-bound deferred-service pattern; stopping an uninitialized service does not create it. Full/Play Kotlin compilation and 52 focused JVM tests (including host launch/fencing and settings lifecycle) passed after this fix. The 32 media component results remain applicable because those sources are unchanged. The corrected APK still requires actual cold-start, task, provider and installation acceptance; the failing candidate is not a public delivery.

## Subsequent device evidence and remaining repairs

The corrected private Alpha24 candidate (code 27, source `b2d414da0f2e11429df2bf767b4807c2a5f845d9`) now cold-starts on Samsung Android 13 and the existing Android API 37 / 16 KiB tablet emulator. Installed APK bytes match SHA-256 `7b69d881e93820afb7a44896ef01e172727ba7dee61d9f124f318a788f923991`; existing task history and provider selections remain present. The tablet reconstructed and installed this exact APK through the real delta path. Samsung exercised full-download fallback and the native installer with the preceding candidate; its startup defect was then corrected using a package replacement. Final update acceptance still needs the next integrated artifact.

On Samsung, two manual terminal sessions executed distinct marker commands and retained separate buffers. One real, once-only `ark-code-latest` scheduled task received its Android alarm while the app was backgrounded, executed a shell command with exit 0, read its resulting file, published an owned snapshot and finished. Saving through the real system file picker produced the same 49-byte file and SHA-256 as the publication receipt. The model interpreted the requested marker as an unset environment variable; this proves the execution/file path, not exact instruction compliance. HTTP request/token counts were not measured; this was one scheduled occurrence, not a claim of one HTTP request.

Device checks exposed two further gaps: project-origin task creation lost the project selection, and the published Markdown output had no in-app opening route. These are active implementation repairs, not unsupported-platform exemptions. Media-provider configuration also refused valid image rows because the Android producer seeded a zero context limit; source checkpoint `bad173323e095a84fa7af81cada435a70cd1d338` repairs the producer without weakening native validation. Twelve focused producer tests passed; configuration and generation acceptance require the next APK. No actual image or video generation request has been submitted in this acceptance run. Public Android Alpha22 and iOS Latest remain unchanged.

The project-list cause is now repaired in source: its SELECT omitted the managed-identity columns required by the original row parser, which silently discarded every returned project. The query now includes those columns; filtering and ownership checks remain intact. The corresponding native regression is authored, not executed. Home selection/error handling and the new owned-output viewer remain part of the pending integrated APK. A focused terminal check also distinguished single-session success from a real concurrent-session defect: the first natural exit while another session remains alive reports a fault, whereas the final session reports exit 0. That settlement repair remains pending; command output alone does not prove successful workspace export.
