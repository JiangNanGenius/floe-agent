# G08 generic platform-tool JNI wiring (Main-owned)

This folder is **source-only**; it is intentionally not part of any Gradle/CMake
build in this lane. The shared Play core carries no phone/ADB/root descriptor,
name, schema, asset or implementation.

## 1. CMake append (Main)

In `core/swiftbridge/src/main/cpp/CMakeLists.txt`, append the new translation
unit to the existing `floe_jni` target (never replace the frozen list):

```cmake
add_library(floe_jni SHARED ... floe_network_artifact_jni.cpp
    platform-tools/floe_platform_tools_jni.cpp)
```

The file resolves `CMAKE_CURRENT_SOURCE_DIR`-relative; either copy it to
`core/swiftbridge/src/main/cpp/` before appending or use
`${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/platform-tools/floe_platform_tools_jni.cpp`.
Copying into the existing cpp directory is the reviewed convention.

`floe_jni` already links `FloeAndroidCore` (the Swift `.so` exporting the
`floe_platform_tool_*` C ABI). No new library, dependency, manifest, resource or
package target is required.

## 2. Symbol map

| Kotlin (`com.floe.android.swiftbridge.PlatformToolsNative`) | JNI C++ | Swift C ABI |
| --- | --- | --- |
| `bind(epoch: Long, catalog: ByteArray): Int` | `..._bind` | `floe_platform_tool_bind` |
| `setAvailability(epoch: Long, namesJson: ByteArray): Int` | `..._setAvailability` | `floe_platform_tool_set_availability` |
| `next(timeoutMillis: Int): Long` | `..._next` | `floe_platform_tool_next` |
| `describe(claim: Long): ByteArray?` | `..._describe` | `floe_platform_tool_describe` |
| `payload(claim: Long): ByteArray?` | `..._payload` | `floe_platform_tool_payload_length` + `..._take_payload` |
| `isLive(claim: Long): Int` | `..._isLive` | `floe_platform_tool_is_live` |
| `shouldStop(claim: Long): Int` | `..._shouldStop` | `floe_platform_tool_should_stop` |
| `complete(claim: Long, status: Int, value: ByteArray): Int` | `..._complete` | `floe_platform_tool_complete` |
| `close(epoch: Long): Int` | `..._close` | `floe_platform_tool_close` |
| `stats(): ByteArray?` | `..._stats` | `floe_platform_tool_stats` |
| `readiness(): ByteArray?` | `..._readiness` | `floe_platform_tool_readiness` |
| `artifactRoot(): ByteArray?` | `..._artifactRoot` | `floe_platform_tool_artifact_root` |

The Kotlin object loads the SAME `floe_jni` library the existing core bridge
loaders pin (`System.loadLibrary("floe_jni")`).

## 3. Full App pump requirements (Main / App integrator)

- Bind ONLY when the Full variant is compiled and the live native root epoch
  exists; call `bind(liveEpoch, catalog)` once per generation. A refused bind
  installs nothing. Never bind in Play.
- Bind leaves EVERY runner unavailable. Immediately after bind, and on every
  real enable/disable change within the SAME epoch, call
  `setAvailability(liveEpoch, namesJson)` with the bounded JSON array of
  actually-usable names (a subset of the registered catalog). Unknown,
  duplicate and oversized sets are refused atomically; metadata/schema are
  unchanged. Disabling fences queued calls; claimed in-flight host work still
  settles exactly once.
- One serialized pump per epoch (the descriptors are all `mainRunOnly` and
  `supportsConcurrentBatchDispatch=false`; the bridge validates that).
- `next()` claim -> `describe()` -> `payload()` -> real typed operation ->
  `complete()` exactly once. `shouldStop()==1` stops new dispatch and cancels
  the real operation; still settle that claim exactly once.
- The trusted ticket descriptor carries task/run/tool-call/idempotency/scope/
  approval-grant identity. The pump MUST use those values, never same-named
  fields from model arguments (reserved names are refused in schemas).
- Before writing a screenshot, read the trusted `artifactRoot()` value: it is
  the ONE mailbox-bound actual owned root (`<live owned root>/FloeAgent`) and
  becomes null after an epoch change/retirement. Write the real PNG (`.png`,
  image/png) or JPEG (`.jpg`/`.jpeg`, image/jpeg) under its EXISTING
  `VNCArtifacts/<uuid>.<ext>` namespace. There is no Foundation/temp fallback.
- Result JSON is closed and bounded. Screenshot evidence must reference those
  real bytes with the actual byte count and SHA-256. `ToolArtifactReference`
  -> `ToolExecutionOutput.artifacts` -> `AgentRuntime.providerImageEvidence`
  (fed by the SAME `RunDomainComponents.artifactRootURL`) is the existing
  vision path; no parallel base64/log transport exists.
- On generation close/rebind, stop the pump and wait for the old epoch; the
  bridge fences waiters and removes owned runners.

## 4. Play boundary

The Kotlin declarations and the generic C++ translation unit contain no tool
name/schema/device identifiers and may be present in the common artifact. Play
never calls `bind`, so zero platform tools are registered or advertised.
