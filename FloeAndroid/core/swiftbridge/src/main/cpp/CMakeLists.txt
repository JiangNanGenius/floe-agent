cmake_minimum_required(VERSION 3.22.1)
project(floe_android_bridge LANGUAGES CXX)
add_library(FloeAndroidCore SHARED IMPORTED)
set_target_properties(FloeAndroidCore PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libFloeAndroidCore.so"
    IMPORTED_NO_SONAME TRUE)
# RB-1 appends floe_runtime_jni.cpp ONLY (new translation unit; the frozen
# floe_jni.cpp and published floe_secret_jni.cpp files are byte-identical).
# If the serialized gateway qualifier changes this line first, rebase this
# single append onto the qualified file — never replace it from an old copy.
#
# CORPUS-FIRST (2026-10-20): floe_security_corpus_jni.cpp appended the same
# way — one additive translation unit inside the SAME floe_jni target; every
# prior wrapper file stays byte-identical.
#
# PROVIDER-CATALOG (2026-10-21): floe_provider_catalog_jni.cpp appended the
# same way — the trusted host freezes the packaged official catalog bytes
# before the Root start; the ordinary bootstrap install injects them into the
# original provider domain. Additive TU only; all prior wrappers unchanged.
#
# PROVIDER-DRAFT-PROBE (2026-10-21): floe_provider_draft_probe_jni.cpp
# appended the same way — the trusted provider editor submits its frozen RAM
# draft candidate + ephemeral key with its own live editor route; native
# dispatches through the ORIGINAL adapter and persists nothing. Additive TU
# only; all prior wrappers unchanged.
#
# PRIVACY-CONFIRMATION (2026-10-21): floe_privacy_jni.cpp appended the same
# way — the privileged one-operation capability ingress for the two privacy
# clears (root/epoch/operation/action/digest/invocation bound). Not a V3
# command and never model-reachable. Additive TU only; all prior wrappers
# unchanged.
#
# R3-CORE-CLOSURE (2026-10-22, job-3d39b56695c44bd2): floe_linux_runtime_
# cleanup_jni.cpp and floe_linux_readiness_jni.cpp appended the same way —
# the typed runtime-UID workspace-cleanup request/receipt lane and the live
# per-generation readiness ingress/invalidation surface. Both are trusted-
# host-only (no V3 key, no model route); all semantics live in
# FloeAndroidCore. Additive TU only; all prior wrappers unchanged.
#
# D04 RUN-OUTPUT CONSUMER (2026-10-27, job-6f953da44de048d0):
# floe_run_output_jni.cpp appended the same way — the narrow epoch-fenced
# trusted-host owned run-output reader/egress lane (exact persisted receipt
# -> lease -> streamed verify -> bounded 64 KiB egress). Not a V3 command,
# never model-reachable; no path/receipt/digest argument ever crosses from
# the JVM side. All semantics live in FloeAndroidCore. Additive TU only;
# all prior wrappers unchanged.
# OFFICE-AI15 (2026-10-27, job-1db1a7a8d5da457a): floe_office_ai_jni.cpp appended
# the same way — the Office AI trusted-host mailbox pump ABI (bind/next/
# describe/payload/isLive/shouldStop/complete/close/stats) over the epoch-bound
# Swift mailbox. Not a V3 command, never model-reachable; all semantics live
# in FloeAndroidCore/OfficeAI (mailbox + edit-context store + bridge). Additive
# TU only; all prior wrappers byte-identical.
# G07.1 NETWORK DIAGNOSTICS (2026-10-30, job-4836dda08fd54e6d):
# floe_network_diagnostics_jni.cpp appended the same way — the trusted-host
# pump ABI (bind/next/describe/payload/isLive/shouldStop/complete/close/stats/
# readiness) over the epoch-fenced Swift network mailbox; the Kotlin pump
# calls the ONE App-owned PhoneNetworkService. Not a V3 command, never
# model-reachable; all validation/ownership lives in FloeAndroidCore. Additive
# TU only; all prior wrappers byte-identical.
# G09-R2 MEDIA RENDER (2026-11-01, job-b72b2978320e484e):
# floe_media_render_jni.cpp appended the same way — the trusted-host bounded
# render-ticket pump ABI (bind/claim/describe/isLive/shouldStop/heartbeat/
# complete/close/stats/rootStop/drainPending) over the epoch-fenced Swift
# mailbox. Not a V3 command, never model-reachable; every lease/root/digest/
# revision/token decision lives in FloeAndroidCore/G09R2. Additive TU only;
# all prior wrappers byte-identical.
# G07.3B NETWORK ARTIFACTS (2026-10-31, job-6ceb057501034a00):
# floe_network_artifact_jni.cpp appended the same way — the trusted-host pump
# ABI (bind/next/describe/payload/isLive/shouldStop/complete/close/stats/
# readiness) over the epoch-fenced Swift saved-artifact mailbox. Not a V3
# command, never model-reachable; all decisions live in FloeAndroidCore and
# the App-private stores. Additive TU only; all prior wrappers byte-identical.
# G09-R2 GENERATION FOREGROUND (2026-11-01, job-6666081a8075473e):
# floe_generation_foreground_jni.cpp appended the same way — the trusted-host
# bounded foreground admission/lease proof for real cloud generation jobs
# (register/deny/release/cancel/snapshot/count/releaseAll). The Kotlin App
# `dataSync` service owns the actual FGS/notification; all job/epoch/token
# validation lives in FloeAndroidCore/G09R2. Not a V3 command, never
# model-reachable. Additive TU only; all prior wrappers byte-identical.
# G09-R2 FOUNDATION AUTHORITY (2026-11-01, job-aa95dd9b26044ded):
# floe_media_foundation_jni.cpp appended the same way — the trusted-host plain
# authority proof (status/verify renderBinding|probeRoot|ticket) and aggregate
# Root-drain (rootStop/drainPending) lane over the SAME bound creative cluster,
# native snapshot lease records and claimed render tickets. Not a V3 command,
# never model-reachable; all decisions live in FloeAndroidCore/G09R2. Additive
# TU only; all prior wrappers byte-identical.
# G09-R2 DESIGN AUTHORITY (2026-11-01, job-6bd337e5e61b4917):
# floe_design_authority_jni.cpp appended the same way — the privileged
# trusted-UI restructure-preservation ingress (prepare/confirm/revoke/retire)
# over the epoch-fenced Swift store. The App calls it only from the explicit
# user confirmation; the design service burns the existing single-use grant
# immediately before freeze/propose/adopt. Not a V3 command, never
# model-reachable; all decisions live in FloeAndroidCore/G09R2/Design.
# Additive TU only; all prior wrappers byte-identical.
# C05 DEVICE COMMUNICATIONS (2026-11-02, job-2f4f7ceefe474948):
# floe_device_communication_jni.cpp appended the same way — the trusted-host
# device model-tool mailbox ABI (bind/next/describe/payload/isLive/shouldStop/
# complete/close/stats/readiness) over the epoch-fenced Swift mailbox. The
# Kotlin App pump performs real TCP/Telnet/BLE/USB operations through the
# App-owned engine. Not a V3 command, never model-reachable; every ownership/
# approval/cancellation decision lives in FloeAndroidCore. Additive TU only;
# all prior wrappers byte-identical.
# C05 RDP (2026-11-02, job-ed2243f494104990): floe_rdp_jni.cpp appended the
# same way — the trusted-host binary RDP frame lane (acquire/read/release)
# over the SAME imported FloeAndroidCore.so. Pixels never cross JSON/base64
# and every epoch/owner/lease check lives in FloeAndroidCore. Additive TU
# only; all prior wrappers byte-identical.
add_library(floe_jni SHARED floe_jni.cpp floe_secret_jni.cpp floe_runtime_jni.cpp floe_attachment_staging_jni.cpp floe_security_corpus_jni.cpp floe_provider_catalog_jni.cpp floe_provider_draft_probe_jni.cpp floe_skills_folder_staging_jni.cpp floe_provider_modelset_jni.cpp floe_privacy_jni.cpp floe_linux_shell_jni.cpp floe_run_foreground_jni.cpp floe_jobs_jni.cpp floe_linux_workspace_jni.cpp floe_linux_runtime_cleanup_jni.cpp floe_linux_readiness_jni.cpp floe_workspace_source_jni.cpp floe_git_trust_jni.cpp floe_terminal_jni.cpp floe_browser_jni.cpp floe_git_actions_jni.cpp floe_network_workspace_jni.cpp floe_run_output_jni.cpp floe_office_ai_jni.cpp floe_network_diagnostics_jni.cpp floe_network_artifact_jni.cpp floe_platform_tools_jni.cpp floe_media_render_jni.cpp floe_media_foundation_jni.cpp floe_generation_foreground_jni.cpp floe_design_authority_jni.cpp floe_mail_transport_jni.cpp floe_vnc_jni.cpp floe_rdp_jni.cpp floe_calendar_host_jni.cpp floe_system_host_jni.cpp
    ../../../../devicecommunication/src/main/cpp/floe_device_communication_jni.cpp)
target_link_libraries(floe_jni PRIVATE FloeAndroidCore)
target_link_options(floe_jni PRIVATE "-Wl,-z,max-page-size=16384")

# Debug instrumentation wrapper for the qualification seam (corpus gate,
# database smoke and JSON-kind smoke). Loads only from the androidTest class
# com.floe.android.bridge.QualificationNative; the frozen floe_jni/v1 path
# above is unchanged. Links against the SAME actual libFloeAndroidCore.so.
# Genuinely debug-variant-only: the flag below is passed by the `debug`
# buildType in core/swiftbridge/build.gradle.kts, so release AAR native
# entries never build or package this wrapper (verified by
# Historical native JNI qualification evidence; the
# prebuilt libFloeAndroidCore.so export table itself is shared across all
# variants and IS inventory-reported, not claimed absent).
option(FLOE_BUILD_QUALIFICATION_JNI "Build the debug-only qualification JNI wrapper" OFF)
if(FLOE_BUILD_QUALIFICATION_JNI)
    add_library(floe_qualification_jni SHARED floe_qualification.cpp)
    target_link_libraries(floe_qualification_jni PRIVATE FloeAndroidCore)
    target_link_options(floe_qualification_jni PRIVATE "-Wl,-z,max-page-size=16384")
endif()
