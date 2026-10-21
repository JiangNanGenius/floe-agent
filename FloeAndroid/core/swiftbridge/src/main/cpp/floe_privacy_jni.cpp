// SPDX-License-Identifier: MPL-2.0
//
// G02 privacy trusted-host confirmation ingress — additive JNI translation
// unit inside the EXISTING floe_jni target.
//
// The App calls these methods ONLY from the explicit confirmation action. The
// live Root epoch + full process owner token are validated by the native
// Swift ingress (`RuntimeFacadeBootstrap.g02OwnerProofValid`) before an
// opaque one-operation `pc:v1:` capability is minted. This is not a V3
// command, has no command/label/scope/matrix entry and is unreachable from
// model-authored envelopes. The owner token never leaves this call.
//
// Discipline mirrors floe_secret_jni.cpp: no global refs, no Swift -> JVM
// callback, complete UTF-16 -> UTF-8 conversion, bounded buffers, typed
// numeric refusal exceptions and no secret/user content in messages.
#include <jni.h>

#include <codecvt>
#include <cstdint>
#include <locale>
#include <string>

extern "C" {
int32_t floe_privacy_confirm_issue(
    int64_t ownerEpoch, const char *ownerToken, const char *operation,
    const char *previewDigest, const char *invocationID, const char *action,
    char *outToken, int32_t outCap);
int32_t floe_privacy_confirm_revoke(int64_t ownerEpoch,
                                    const char *ownerToken,
                                    const char *token);
int32_t floe_privacy_confirm_retire(int64_t ownerEpoch,
                                    const char *ownerToken);
}

namespace {

constexpr size_t kMaximumOwnerTokenBytes = 64;
constexpr size_t kMaximumOperationBytes = 64;
constexpr size_t kMaximumDigestBytes = 80;
constexpr size_t kMaximumInvocationBytes = 256;
constexpr size_t kMaximumActionBytes = 32;
constexpr size_t kMaximumTokenBytes = 64;

bool FloeValidUtf16(const jchar *chars, jsize length) {
    if (!chars || length < 0) return false;
    for (jsize index = 0; index < length; ++index) {
        const uint32_t unit = static_cast<uint32_t>(chars[index]);
        if (unit >= 0xD800 && unit <= 0xDBFF) {
            if (index + 1 >= length) return false;
            const uint32_t low = static_cast<uint32_t>(chars[++index]);
            if (low < 0xDC00 || low > 0xDFFF) return false;
        } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
            return false;
        }
    }
    return true;
}

bool FloeUtf8FromJString(JNIEnv *env, jstring value, size_t maximumBytes,
                         std::string &output) {
    output.clear();
    if (!value) return false;
    const jsize length = env->GetStringLength(value);
    if (length < 0 || static_cast<size_t>(length) > maximumBytes) return false;
    const jchar *chars = env->GetStringChars(value, nullptr);
    if (!chars) return false;
    bool ok = false;
    try {
        if (FloeValidUtf16(chars, length)) {
            std::u16string utf16(reinterpret_cast<const char16_t *>(chars),
                                 static_cast<size_t>(length));
            std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
            output = converter.to_bytes(utf16);
            ok = converter.converted() == utf16.size();
        }
    } catch (...) {
        ok = false;
    }
    env->ReleaseStringChars(value, chars);
    if (!ok || output.size() > maximumBytes ||
        output.find('\0') != std::string::npos) {
        output.clear();
        return false;
    }
    return true;
}

bool FloeAscii(const char *data, int32_t length) {
    if (!data || length < 0) return false;
    for (int32_t index = 0; index < length; ++index) {
        if (static_cast<unsigned char>(data[index]) >= 0x80) return false;
    }
    return true;
}

void FloeThrowStatus(JNIEnv *env, jint status) {
    if (env->ExceptionCheck()) return;
    jclass exceptionClass = env->FindClass(
        "com/floe/android/bridge/PrivacyConfirmationNativeException");
    if (exceptionClass) {
        jmethodID constructor = env->GetMethodID(exceptionClass, "<init>", "(I)V");
        if (constructor) {
            jobject exception = env->NewObject(exceptionClass, constructor, status);
            env->DeleteLocalRef(exceptionClass);
            if (exception) {
                env->Throw(reinterpret_cast<jthrowable>(exception));
                return;
            }
        } else {
            env->DeleteLocalRef(exceptionClass);
        }
    }
    if (env->ExceptionCheck()) return;
    jclass fallback = env->FindClass("java/lang/IllegalStateException");
    if (fallback) {
        env->ThrowNew(fallback, "privacy_confirmation_failure");
        env->DeleteLocalRef(fallback);
    }
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_PrivacyConfirmationNative_issue(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken,
    jstring operation, jstring previewDigest, jstring invocationID,
    jstring action) {
    try {
        if (ownerEpoch <= 0) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        std::string owner;
        std::string op;
        std::string digest;
        std::string invocation;
        std::string actionValue;
        if (!FloeUtf8FromJString(env, ownerToken, kMaximumOwnerTokenBytes, owner) ||
            !FloeUtf8FromJString(env, operation, kMaximumOperationBytes, op) ||
            !FloeUtf8FromJString(env, previewDigest, kMaximumDigestBytes, digest) ||
            !FloeUtf8FromJString(env, invocationID, kMaximumInvocationBytes,
                                 invocation) ||
            !FloeUtf8FromJString(env, action, kMaximumActionBytes, actionValue)) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        char token[64];
        const int32_t result = floe_privacy_confirm_issue(
            static_cast<int64_t>(ownerEpoch), owner.c_str(), op.c_str(),
            digest.c_str(), invocation.c_str(), actionValue.c_str(),
            token, static_cast<int32_t>(sizeof(token)));
        if (result != 0) {
            FloeThrowStatus(env, result);
            return nullptr;
        }
        if (!FloeAscii(token, 38)) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        return env->NewStringUTF(token);
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return nullptr;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_PrivacyConfirmationNative_revoke(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken, jstring token) {
    try {
        if (ownerEpoch <= 0 || !token) {
            FloeThrowStatus(env, -105);
            return -105;
        }
        std::string owner;
        std::string value;
        if (!FloeUtf8FromJString(env, ownerToken, kMaximumOwnerTokenBytes, owner) ||
            !FloeUtf8FromJString(env, token, kMaximumTokenBytes, value)) {
            FloeThrowStatus(env, -105);
            return -105;
        }
        return floe_privacy_confirm_revoke(
            static_cast<int64_t>(ownerEpoch), owner.c_str(), value.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return -105;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_PrivacyConfirmationNative_retire(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken) {
    try {
        if (ownerEpoch <= 0) {
            FloeThrowStatus(env, -105);
            return -105;
        }
        std::string owner;
        if (!FloeUtf8FromJString(env, ownerToken, kMaximumOwnerTokenBytes, owner)) {
            FloeThrowStatus(env, -105);
            return -105;
        }
        return floe_privacy_confirm_retire(static_cast<int64_t>(ownerEpoch),
                                           owner.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return -105;
    }
}
