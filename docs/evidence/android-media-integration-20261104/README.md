# Android media integration checkpoint — 2026-11-04

This is a source checkpoint, not an installable delivery or a claim of full application acceptance.

- iOS behavior reference: `36f63bf400dfaa3a127259eac006b38d72516390`. Existing feature and gap IDs remain unchanged.
- Model-facing image/video tools now connect to the original generation adapters, durable job records, task-owned workspace delivery, shared worker lifecycle and cancellation. Dispatch intent and accepted handles survive unknown outcomes; work is not silently replayed.
- Media enhancement adds task-Linux FFmpeg interpolation, measured source/output contracts, a configurable cloud super-resolution backend and editor/settings entry points. No local AI model or plain-resize substitution is introduced.
- Enhancer credentials use the original sealed secure ingress, native vault ownership and immutable credential rotation. Business JSON carries an opaque one-use intent, never secret bytes.
- Integration repairs cover Android-supported bounded HTTP streaming, actual upload bodies, awaited progress, serialized journal updates, bounded worker admission, input lifetime and staged output publication that preserves existing files on precommit failure.
- Provider navigation uses a compact title after scrolling. Android-specific system permission and installation UI remains native.

## Verification boundary

Swift 6 ARM64 release object compilation passed before the final interpolation/publication lifecycle corrections. The final production link must cover those corrections. Full/Play application and runtime Kotlin compilation passed. Focused JVM contracts passed (27 tests, zero failures); these cover the enhancer host, provider catalog and enhancement value contracts. Swift regression tests are authored and remain unexecuted; no test count is presented as passed.

Final production libraries, signed APK, Samsung/tablet acceptance, actual provider calls and full/delta upgrade installation remain separate pending gates. Public Android Alpha22 and the iOS Latest pointer are unchanged.

## Real-provider test routing

Use the existing Ark Plan configuration with `ark-code-latest` for LLM testing and its configured image route. Video generation uses the separately authorized Volcengine pay-as-you-go route because the plan excludes it. Perform one minimum supported request per media scenario, stop on failure or unknown acceptance, and do not automatically resubmit or switch paid providers. A successful model-list response is not proof of working generation.
