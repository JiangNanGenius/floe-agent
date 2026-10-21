// SPDX-License-Identifier: MPL-2.0
//
// Trusted provider-catalog handoff — JNI adapter (NEW additive translation
// unit inside the EXISTING floe_jni target). The frozen floe_jni.cpp, the
// published floe_secret_jni.cpp, floe_runtime_jni.cpp,
// floe_attachment_staging_jni.cpp and floe_security_corpus_jni.cpp stay
// byte-identical.
//
// This is NOT a bridge command: the App bootstrap reads the packaged,
// reviewed `provider/ProviderCatalog.json` asset and freezes those bytes into
// the native Root BEFORE the Root start. The ordinary bootstrap install then
// passes the frozen bytes into the original provider domain
// (ModelConfigurationFacade catalog slot), whose validation is the ORIGINAL
// ProviderCatalogIndex decoder (schemaVersion/providers/source + per-entry
// Codable) with the original 2 MiB document bound. A missing/tampered/
// oversized/invalid catalog never freezes and catalog commands keep their
// truthful typed `needsConfiguration(catalogNotInjected)` refusal.
//
// Discipline (mirrors the reviewed security-corpus TU):
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * typed status returned as jint (0 ok / 1 idempotent / negative refusal);
//    document bytes and digests never enter an exception message;
//  * hard byte bound checked BEFORE copying the array.
#include <jni.h>

#include <cstdint>

extern "C" {
// G02HostCatalog.swift — trusted host bootstrap seam (additive symbol).
int32_t floe_host_catalog_freeze(const uint8_t *bytes, int32_t length);
}

namespace {

// Mirrors ProviderCatalogIndex.maximumDocumentBytes (FloeProviders).
constexpr int32_t kMaximumCatalogBytes = 2 * 1024 * 1024;

}  // namespace

// Freeze the trusted catalog bytes read by the host from the packaged asset.
// Anything but 0/1 means "not frozen": the ordinary install keeps the typed
// catalogNotInjected refusal; never a fabricated catalog.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_ProviderCatalogNative_providerCatalogFreeze(
    JNIEnv *env, jobject, jbyteArray catalogBytes) {
    if (!env) return -499;
    if (!catalogBytes) return -105;  // invalidArguments
    const jsize length = env->GetArrayLength(catalogBytes);
    if (length < 0) return -105;
    if (length == 0) return -431;                  // empty
    if (length > kMaximumCatalogBytes) return -432; // oversized (no copy)
    jboolean isCopy = JNI_FALSE;
    const jbyte *bytes = env->GetByteArrayElements(catalogBytes, &isCopy);
    if (!bytes) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return -499;  // internal
    }
    const int32_t status = floe_host_catalog_freeze(
        reinterpret_cast<const uint8_t *>(bytes), static_cast<int32_t>(length));
    env->ReleaseByteArrayElements(catalogBytes, const_cast<jbyte *>(bytes),
                                  JNI_ABORT);
    return status;
}
