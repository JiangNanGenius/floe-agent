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
add_library(floe_jni SHARED floe_jni.cpp floe_secret_jni.cpp floe_runtime_jni.cpp floe_attachment_staging_jni.cpp floe_security_corpus_jni.cpp floe_provider_catalog_jni.cpp floe_provider_draft_probe_jni.cpp floe_skills_folder_staging_jni.cpp floe_provider_modelset_jni.cpp)
target_link_libraries(floe_jni PRIVATE FloeAndroidCore)
target_link_options(floe_jni PRIVATE "-Wl,-z,max-page-size=16384")

# Debug instrumentation wrapper for the qualification seam (corpus gate,
# database smoke and JSON-kind smoke). Loads only from the androidTest class
# com.floe.android.bridge.QualificationNative; the frozen floe_jni/v1 path
# above is unchanged. Links against the SAME actual libFloeAndroidCore.so.
# Genuinely debug-variant-only: the flag below is passed by the `debug`
# buildType in core/swiftbridge/build.gradle.kts, so release AAR native
# entries never build or package this wrapper (verified by
# Local/Private/android-g02-20261018/native-jni-qualification evidence; the
# prebuilt libFloeAndroidCore.so export table itself is shared across all
# variants and IS inventory-reported, not claimed absent).
option(FLOE_BUILD_QUALIFICATION_JNI "Build the debug-only qualification JNI wrapper" OFF)
if(FLOE_BUILD_QUALIFICATION_JNI)
    add_library(floe_qualification_jni SHARED floe_qualification.cpp)
    target_link_libraries(floe_qualification_jni PRIVATE FloeAndroidCore)
    target_link_options(floe_qualification_jni PRIVATE "-Wl,-z,max-page-size=16384")
endif()
