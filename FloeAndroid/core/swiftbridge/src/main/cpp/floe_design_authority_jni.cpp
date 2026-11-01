// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 design-authority trusted-host ingress — additive JNI translation unit
// inside the EXISTING floe_jni target.
//
// The App calls `prepare` ONLY from the explicit preservation-confirmation
// action with its live accepted Root epoch + full process owner token. Native
// validates the owner proof, binds the exact live target/operation/base, and
// returns display JSON + an opaque token. `confirm` mints the existing
// single-use grant; the design service burns it immediately before an effect.
// This is not a V3 command and is unreachable from model-authored JSON.
//
// Discipline mirrors floe_privacy_jni.cpp: no global refs, no Swift -> JVM
// callback, complete UTF-16/UTF-8 conversion, bounded buffers, typed numeric
// refusal exceptions and no user content in messages.
#include <jni.h>

#include <codecvt>
#include <cstdint>
#include <cstring>
#include <locale>
#include <string>
#include <vector>

extern "C" {
int32_t floe_design_authority_prepare(
    int64_t ownerEpoch, const char *ownerToken, const char *requestJSON,
    char *outJSON, int32_t outCapacity);
int32_t floe_design_authority_confirm(int64_t ownerEpoch,
                                      const char *ownerToken,
                                      const char *token);
int32_t floe_design_authority_revoke(int64_t ownerEpoch,
                                     const char *ownerToken,
                                     const char *token);
int32_t floe_design_authority_retire(int64_t ownerEpoch,
                                     const char *ownerToken);
}

namespace {

constexpr size_t kMaximumOwnerTokenBytes = 64;
constexpr size_t kMaximumTokenBytes = 64;
constexpr size_t kMaximumPrepareJsonBytes = 64 * 1024;
constexpr size_t kMaximumDisplayJsonBytes = 64 * 1024;

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

jstring FloeJStringFromUtf8(JNIEnv *env, const std::string &value) {
    try {
        std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> converter;
        const std::u16string utf16 = converter.from_bytes(value);
        if (converter.converted() != value.size()) return nullptr;
        return env->NewString(
            reinterpret_cast<const jchar *>(utf16.data()),
            static_cast<jsize>(utf16.size()));
    } catch (...) {
        return nullptr;
    }
}

void FloeThrowStatus(JNIEnv *env, jint status) {
    if (env->ExceptionCheck()) return;
    jclass exceptionClass = env->FindClass(
        "com/floe/android/bridge/DesignAuthorityNativeException");
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
        env->ThrowNew(fallback, "design_authority_failure");
        env->DeleteLocalRef(fallback);
    }
}

bool FloeReadToken(JNIEnv *env, jstring value, std::string &output) {
    if (!FloeUtf8FromJString(env, value, kMaximumTokenBytes, output)) {
        return false;
    }
    if (output.empty() || output.rfind("dra:v1:", 0) != 0) return false;
    for (size_t index = 7; index < output.size(); ++index) {
        const char c = output[index];
        const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!hex) return false;
    }
    return true;
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_DesignAuthorityNative_prepare(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken,
    jstring requestJSON) {
    try {
        if (ownerEpoch <= 0) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        std::string owner;
        std::string request;
        if (!FloeUtf8FromJString(env, ownerToken, kMaximumOwnerTokenBytes, owner) ||
            !FloeUtf8FromJString(env, requestJSON, kMaximumPrepareJsonBytes,
                                 request) ||
            owner.empty() || request.empty()) {
            FloeThrowStatus(env, -105);
            return nullptr;
        }
        std::vector<char> output(kMaximumDisplayJsonBytes, 0);
        const int32_t result = floe_design_authority_prepare(
            static_cast<int64_t>(ownerEpoch), owner.c_str(), request.c_str(),
            output.data(), static_cast<int32_t>(output.size()));
        if (result != 0) {
            FloeThrowStatus(env, result);
            return nullptr;
        }
        output.back() = 0;
        const std::string json(output.data());
        jstring value = FloeJStringFromUtf8(env, json);
        if (!value) {
            FloeThrowStatus(env, -105);
        }
        return value;
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return nullptr;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DesignAuthorityNative_confirm(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken, jstring token) {
    try {
        if (ownerEpoch <= 0) return -105;
        std::string owner;
        std::string value;
        if (!FloeUtf8FromJString(env, ownerToken, kMaximumOwnerTokenBytes, owner) ||
            !FloeReadToken(env, token, value)) {
            return -105;
        }
        return floe_design_authority_confirm(
            static_cast<int64_t>(ownerEpoch), owner.c_str(), value.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return -105;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DesignAuthorityNative_revoke(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken, jstring token) {
    try {
        if (ownerEpoch <= 0) return -105;
        std::string owner;
        std::string value;
        if (!FloeUtf8FromJString(env, ownerToken, kMaximumOwnerTokenBytes, owner) ||
            !FloeReadToken(env, token, value)) {
            return -105;
        }
        return floe_design_authority_revoke(
            static_cast<int64_t>(ownerEpoch), owner.c_str(), value.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return -105;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_DesignAuthorityNative_retire(
    JNIEnv *env, jobject, jlong ownerEpoch, jstring ownerToken) {
    try {
        if (ownerEpoch <= 0) return -105;
        std::string owner;
        if (!FloeUtf8FromJString(env, ownerToken, kMaximumOwnerTokenBytes, owner)) {
            return -105;
        }
        return floe_design_authority_retire(
            static_cast<int64_t>(ownerEpoch), owner.c_str());
    } catch (...) {
        if (!env->ExceptionCheck()) FloeThrowStatus(env, -105);
        return -105;
    }
}
