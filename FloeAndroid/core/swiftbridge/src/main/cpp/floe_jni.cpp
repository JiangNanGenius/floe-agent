// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <codecvt>
#include <locale>
#include <string>

extern "C" const char *floe_bridge_exchange(const char *request);
extern "C" void floe_bridge_free(const char *response);

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_SwiftCore_exchange(JNIEnv *env, jobject, jstring request) {
    if (!request) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Missing bridge request");
        return nullptr;
    }
    const jsize size = env->GetStringLength(request);
    if (size > 65536) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Bridge request too large");
        return nullptr;
    }
    const jchar *chars = env->GetStringChars(request, nullptr);
    if (!chars) return nullptr;
    std::u16string input(reinterpret_cast<const char16_t *>(chars), size);
    env->ReleaseStringChars(request, chars);
    try {
        std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t> codec;
        const std::string utf8 = codec.to_bytes(input);
        if (utf8.size() > 65536 || utf8.find('\0') != std::string::npos) {
            env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Invalid bridge request size or NUL");
            return nullptr;
        }
        const char *response = floe_bridge_exchange(utf8.c_str());
        if (!response) {
            env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), "Shared core returned no response");
            return nullptr;
        }
        // Copy before freeing, including the exception path during Unicode conversion.
        const std::string output(response);
        floe_bridge_free(response);
        const std::u16string decoded = codec.from_bytes(output);
        return env->NewString(reinterpret_cast<const jchar *>(decoded.data()), static_cast<jsize>(decoded.size()));
    } catch (const std::exception &) {
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"), "Invalid bridge encoding");
        return nullptr;
    }
}
