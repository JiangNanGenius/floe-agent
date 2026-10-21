// SPDX-License-Identifier: MPL-2.0
//
// Trusted-host PROVIDER MODEL-SET staging — JNI adapter (NEW additive
// translation unit inside the EXISTING floe_jni target; every prior wrapper
// file stays byte-identical; the CMake append lands as a separate private
// patch for Main's serialized composition).
//
// This is NOT a bridge command: no command name, payload vocabulary or
// permission; unreachable from the model/tool wire. The provider editor
// freezes its complete selected-model body in bounded ordered/idempotent
// chunks bound to its own live `rt:v1:` editor route + the actual provider
// id / base revision / create intent, seals the immutable set, and carries
// ONLY the frozen `ms:v1:<32hex>.<64hex>` reference in the save candidate.
// Chunk payloads are model METADATA rows only — never secret bytes — and
// every size/shape/order/binding refusal happens natively BEFORE any
// mutation; nothing here persists anything.
//
// The stage id / frozen reference / route tokens are canonical ASCII
// (`msb:v1:`/`ms:v1:`/`rt:v1:` + lowercase hex + one dot); GetStringUTFChars
// is used only to READ them, and outputs are ASCII NewStringUTF. Chunk
// model JSON crosses as a RAW byte array (GetByteArrayElements), mirroring
// the draft-probe wrapper's binary candidate handling — no UTF-16 round
// trip of model content, no truncation, no re-encoding.
#include <jni.h>

#include <cstdint>
#include <string>
#include <vector>

extern "C" {
// RuntimeFacadeProviderModelSets.swift — trusted host seam (additive
// symbols; same class as floe_host_draft_probe_*).
int32_t floe_host_model_set_begin(const char *providerID,
                                  const char *baseResourceID,
                                  const char *baseVersion,
                                  int32_t createIntent,
                                  const char *routeToken,
                                  char *outHandle,
                                  int32_t outCapacity);
int32_t floe_host_model_set_append(const char *stageID,
                                   const char *routeToken,
                                   int32_t index,
                                   const uint8_t *chunk,
                                   int32_t chunkLength);
int32_t floe_host_model_set_seal(const char *stageID,
                                 const char *routeToken,
                                 int32_t expectedCount,
                                 char *outRef,
                                 int32_t outCapacity);
int32_t floe_host_model_set_cancel(const char *stageID,
                                   const char *routeToken);
}

namespace {

// Mirrors ProviderModelSetStatus capacities/bounds.
constexpr int32_t kHandleCapacity = 40;    // msb:v1:<32hex> + NUL
constexpr int32_t kRefCapacity = 128;      // ms:v1:<32hex>.<64hex> + NUL
constexpr int32_t kStatusOk = 0;
constexpr int32_t kStatusInvalidArgument = -105;
// Proven per-chunk bound (config.model.save payload class; the native
// registry re-enforces it authoritatively — this is only the copy guard).
constexpr int32_t kMaximumChunkBytes = 60 * 1024;  // 61,440

std::string readJavaString(JNIEnv *env, jstring value) {
    if (!env || !value) return std::string();
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return std::string();
    }
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_ProviderModelSetNative_beginModelSet(
    JNIEnv *env, jobject, jstring providerID, jstring baseResourceID,
    jstring baseVersion, jboolean createIntent, jstring routeToken) {
    if (!env || !providerID || !baseResourceID || !baseVersion || !routeToken) {
        return nullptr;
    }
    const std::string provider = readJavaString(env, providerID);
    const std::string resource = readJavaString(env, baseResourceID);
    const std::string version = readJavaString(env, baseVersion);
    const std::string route = readJavaString(env, routeToken);
    if (provider.empty() || resource.empty() || version.empty() || route.empty()) {
        return nullptr;
    }
    char handle[kHandleCapacity];
    const int32_t status = floe_host_model_set_begin(
        provider.c_str(), resource.c_str(), version.c_str(),
        createIntent ? 1 : 0, route.c_str(), handle, kHandleCapacity);
    if (status != kStatusOk) return nullptr;
    handle[kHandleCapacity - 1] = 0;
    return env->NewStringUTF(handle);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_ProviderModelSetNative_appendModelSetChunk(
    JNIEnv *env, jobject, jstring stageID, jstring routeToken, jint index,
    jbyteArray chunk) {
    if (!env || !stageID || !routeToken || !chunk || index < 0) {
        return kStatusInvalidArgument;
    }
    const std::string stage = readJavaString(env, stageID);
    const std::string route = readJavaString(env, routeToken);
    if (stage.empty() || route.empty()) return kStatusInvalidArgument;
    const jsize length = env->GetArrayLength(chunk);
    if (length <= 0 || length > kMaximumChunkBytes) {
        return -116;  // typed chunkTooLarge (native re-checks authoritatively)
    }
    jboolean isCopy = JNI_FALSE;
    jbyte *bytes = env->GetByteArrayElements(chunk, &isCopy);
    if (!bytes) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return kStatusInvalidArgument;
    }
    const int32_t status = floe_host_model_set_append(
        stage.c_str(), route.c_str(), static_cast<int32_t>(index),
        reinterpret_cast<const uint8_t *>(bytes), static_cast<int32_t>(length));
    // Copies only: the JVM array is the App's own RAM buffer.
    env->ReleaseByteArrayElements(chunk, bytes, JNI_ABORT);
    return static_cast<jint>(status);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_ProviderModelSetNative_sealModelSet(
    JNIEnv *env, jobject, jstring stageID, jstring routeToken,
    jint expectedCount) {
    if (!env || !stageID || !routeToken || expectedCount < 0) return nullptr;
    const std::string stage = readJavaString(env, stageID);
    const std::string route = readJavaString(env, routeToken);
    if (stage.empty() || route.empty()) return nullptr;
    char ref[kRefCapacity];
    const int32_t status = floe_host_model_set_seal(
        stage.c_str(), route.c_str(), static_cast<int32_t>(expectedCount),
        ref, kRefCapacity);
    if (status != kStatusOk) return nullptr;
    ref[kRefCapacity - 1] = 0;
    return env->NewStringUTF(ref);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_ProviderModelSetNative_cancelModelSet(
    JNIEnv *env, jobject, jstring stageID, jstring routeToken) {
    if (!env || !stageID || !routeToken) return kStatusInvalidArgument;
    const std::string stage = readJavaString(env, stageID);
    const std::string route = readJavaString(env, routeToken);
    if (stage.empty() || route.empty()) return kStatusInvalidArgument;
    return static_cast<jint>(
        floe_host_model_set_cancel(stage.c_str(), route.c_str()));
}
