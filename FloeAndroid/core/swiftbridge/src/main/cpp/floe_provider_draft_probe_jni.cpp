// SPDX-License-Identifier: MPL-2.0
//
// Trusted-host DRAFT probe/discovery — JNI adapter (NEW additive translation
// unit inside the EXISTING floe_jni target; every prior wrapper file stays
// byte-identical).
//
// This is NOT a bridge command: it has no command name, payload vocabulary or
// permission, and is unreachable from the model/tool wire. The App provider
// editor freezes the EXACT closed save candidate from its RAM draft plus the
// bounded ephemeral key typed in that same session, and submits it with its
// own `rt:v1:` editor route handle. Native re-validates the route against the
// accepted Root epoch + live provider editor incarnation, maps the candidate
// through the ORIGINAL draft builder and dispatches through the ORIGINAL
// provider adapter under the SAME transport admission gate as the saved probe.
// Nothing is persisted.
//
// Result envelope (bridge-local, documented):
//   "P"            still running
//   "S" + <json>   settled payload (exact ConfigProbeOutcome object, or a
//                  typed {status:"failed",errorCode,reason} / cancelled object)
//   "R" + <int>    typed refusal (route retired / invalid handle / oversized)
// The entered key is never returned, copied into the payload or echoed in an
// error; errors are redacted by the ORIGINAL SecretRedactor in the dispatch
// path.
#include <jni.h>

#include <codecvt>
#include <cstdint>
#include <locale>
#include <string>
#include <vector>

extern "C" {
// G02HostDraftProbe.swift — trusted host seam (additive symbols).
int32_t floe_host_draft_probe_submit(const uint8_t *candidateJSON,
                                     int32_t candidateLength,
                                     const uint8_t *secret,
                                     int32_t secretLength,
                                     const char *routeToken,
                                     char *outHandle,
                                     int32_t outCapacity);
int32_t floe_host_draft_probe_result(const char *handle,
                                     const char *routeToken,
                                     uint8_t *outPayload,
                                     int32_t outCapacity,
                                     int32_t *outLength);
int32_t floe_host_draft_probe_cancel(const char *handle,
                                     const char *routeToken);
}

namespace {

// Mirrors G02HostDraftProbeStatus.handleCapacity / buffer/payload bounds.
constexpr int32_t kHandleCapacity = 40;
constexpr int32_t kStatusOk = 0;
constexpr int32_t kStatusPending = 2;
constexpr int32_t kStatusBufferTooSmall = -121;
constexpr int32_t kStatusPayloadTooLarge = -116;
constexpr int32_t kMaximumSettledPayload = 1 * 1024 * 1024;

std::string readJavaString(JNIEnv *env, jstring value) {
    if (!env || !value) return std::string();
    // Handles/routes are ASCII `rt:v1:`/`dp:v1:` identities; GetStringUTFChars
    // is only used to READ them (never to re-encode arbitrary payloads).
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (!chars) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return std::string();
    }
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

// Strict UTF-8 -> UTF-16 conversion for RESULT envelopes (the reviewed
// floe_jni.cpp pattern): settled payloads carry STANDARD UTF-8 JSON with
// arbitrary provider-supplied text (Chinese names, emoji, supplementary
// planes). NewStringUTF would corrupt or reject non-BMP content, so the
// boundary decodes strictly and returns a NEWSTRING of UTF-16; an invalid
// sequence is a typed refusal (never a silent replacement, never a C++
// exception crossing JNI). The tag/status prefix is ASCII.
jstring envelopeStatus(JNIEnv *env, int32_t status);

jstring envelope(JNIEnv *env, char tag, const uint8_t *payload, int32_t length) {
    std::u16string out;
    out.push_back(static_cast<char16_t>(tag));
    try {
        if (payload && length > 0) {
            std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
            const std::u16string decoded = codec.from_bytes(
                reinterpret_cast<const char *>(payload),
                reinterpret_cast<const char *>(payload) + length);
            out.append(decoded);
        }
    } catch (const std::exception &) {
        return envelopeStatus(env, -105);  // typed invalid-payload refusal
    }
    return env->NewString(reinterpret_cast<const jchar *>(out.data()),
                          static_cast<jsize>(out.size()));
}

jstring envelopeStatus(JNIEnv *env, int32_t status) {
    std::string out("R");
    out.append(std::to_string(status));
    return env->NewStringUTF(out.c_str());
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_ProviderDraftProbeNative_submitDraftProbe(
    JNIEnv *env, jobject, jbyteArray candidate, jbyteArray secret,
    jstring routeToken) {
    if (!env) return nullptr;
    if (!candidate || !routeToken) return nullptr;
    const jsize candidateLength = env->GetArrayLength(candidate);
    if (candidateLength <= 0) return nullptr;
    const jsize secretLength = secret ? env->GetArrayLength(secret) : 0;
    if (secretLength < 0) return nullptr;
    const std::string route = readJavaString(env, routeToken);
    if (route.empty()) return nullptr;
    jboolean isCopy = JNI_FALSE;
    jbyte *candidateBytes = env->GetByteArrayElements(candidate, &isCopy);
    if (!candidateBytes) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return nullptr;
    }
    jbyte *secretBytes = nullptr;
    if (secretLength > 0) {
        secretBytes = env->GetByteArrayElements(secret, &isCopy);
        if (!secretBytes) {
            if (env->ExceptionCheck()) env->ExceptionClear();
            env->ReleaseByteArrayElements(candidate, candidateBytes, JNI_ABORT);
            return nullptr;
        }
    }
    char handle[kHandleCapacity];
    const int32_t status = floe_host_draft_probe_submit(
        reinterpret_cast<const uint8_t *>(candidateBytes),
        static_cast<int32_t>(candidateLength),
        reinterpret_cast<const uint8_t *>(secretBytes),
        static_cast<int32_t>(secretLength),
        route.c_str(), handle, kHandleCapacity);
    // Copies only: the JVM arrays are the RAM draft's own buffers.
    env->ReleaseByteArrayElements(candidate, candidateBytes, JNI_ABORT);
    if (secretBytes) {
        env->ReleaseByteArrayElements(secret, secretBytes, JNI_ABORT);
    }
    if (status != kStatusOk) return nullptr;
    handle[kHandleCapacity - 1] = 0;
    return env->NewStringUTF(handle);
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_ProviderDraftProbeNative_pollDraftProbe(
    JNIEnv *env, jobject, jstring handle, jstring routeToken) {
    if (!env || !handle || !routeToken) return nullptr;
    const std::string handleValue = readJavaString(env, handle);
    const std::string route = readJavaString(env, routeToken);
    if (handleValue.empty() || route.empty()) return nullptr;
    uint8_t scratch[512];
    int32_t length = 0;
    int32_t status = floe_host_draft_probe_result(
        handleValue.c_str(), route.c_str(), scratch, sizeof(scratch), &length);
    if (status == kStatusPending) return envelope(env, 'P', nullptr, 0);
    if (status == kStatusBufferTooSmall) {
        if (length <= 0 || length > kMaximumSettledPayload) {
            return envelopeStatus(env, kStatusPayloadTooLarge);
        }
        std::vector<uint8_t> payload(static_cast<size_t>(length));
        int32_t lengthAgain = 0;
        status = floe_host_draft_probe_result(
            handleValue.c_str(), route.c_str(), payload.data(), length,
            &lengthAgain);
        if (status != kStatusOk || lengthAgain != length) {
            return envelopeStatus(env, status == kStatusOk ? kStatusPayloadTooLarge
                                                           : status);
        }
        return envelope(env, 'S', payload.data(), length);
    }
    if (status != kStatusOk) return envelopeStatus(env, status);
    return envelope(env, 'S', scratch, length);
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_ProviderDraftProbeNative_cancelDraftProbe(
    JNIEnv *env, jobject, jstring handle, jstring routeToken) {
    if (!env || !handle || !routeToken) return -105;
    const std::string handleValue = readJavaString(env, handle);
    const std::string route = readJavaString(env, routeToken);
    if (handleValue.empty() || route.empty()) return -105;
    return static_cast<jint>(
        floe_host_draft_probe_cancel(handleValue.c_str(), route.c_str()));
}
