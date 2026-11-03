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

Use the existing Ark Plan configuration with `ark-code-latest` for LLM testing and its configured image route. Video generation uses the separately authorized Volcengine pay-as-you-go route because the plan excludes it. Perform one minimum supported request per media scenario, stop on failure or unknown acceptance, and do not automatically resubmit or switch paid providers. A successful model-list response is not proof of working generation.

## Cold-start follow-up

The first installed candidate exposed eager font-pump creation before the RuntimeHost factory injected its Android Context. Font startup now follows the existing context-bound deferred-service pattern; stopping an uninitialized service does not create it. Full/Play Kotlin compilation and 52 focused JVM tests (including host launch/fencing and settings lifecycle) passed after this fix. The 32 media component results remain applicable because those sources are unchanged. The corrected APK still requires actual cold-start, task, provider and installation acceptance; the failing candidate is not a public delivery.
