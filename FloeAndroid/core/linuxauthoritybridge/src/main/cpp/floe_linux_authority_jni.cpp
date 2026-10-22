// SPDX-License-Identifier: MPL-2.0
#include <jni.h>
#include <dlfcn.h>
#include <cstring>
#include <string>

namespace {
constexpr size_t limit = 65536;
using Exchange = const char *(*)(const char *);
using Free = void (*)(const char *);

void fail(JNIEnv *env, const char *message) {
    jclass type = env->FindClass("java/lang/IllegalStateException");
    if (type) { env->ThrowNew(type, message); env->DeleteLocalRef(type); }
}
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_floe_android_bridge_LinuxAuthorityNative_exchange(JNIEnv *env, jobject, jstring request) {
    if (!request) { fail(env, "Missing environment authority request"); return nullptr; }
    // Use standard UTF-8 rather than JNI modified UTF-8 in both directions.
    jclass stringClass = env->FindClass("java/lang/String");
    if (!stringClass) return nullptr;
    jmethodID getBytes = env->GetMethodID(stringClass, "getBytes", "(Ljava/lang/String;)[B");
    jmethodID constructor = env->GetMethodID(stringClass, "<init>", "([BLjava/lang/String;)V");
    jstring encoding = env->NewStringUTF("UTF-8");
    if (!getBytes || !constructor || !encoding) { env->DeleteLocalRef(stringClass); return nullptr; }
    auto bytes = static_cast<jbyteArray>(env->CallObjectMethod(request, getBytes, encoding));
    if (env->ExceptionCheck() || !bytes) {
        env->DeleteLocalRef(encoding); env->DeleteLocalRef(stringClass); return nullptr;
    }
    const jsize length = env->GetArrayLength(bytes);
    if (length <= 0 || static_cast<size_t>(length) > limit) {
        env->DeleteLocalRef(bytes); env->DeleteLocalRef(encoding); env->DeleteLocalRef(stringClass);
        fail(env, "Environment authority request size invalid"); return nullptr;
    }
    std::string input(static_cast<size_t>(length), '\0');
    env->GetByteArrayRegion(bytes, 0, length, reinterpret_cast<jbyte *>(input.data()));
    env->DeleteLocalRef(bytes);
    if (env->ExceptionCheck()) { env->DeleteLocalRef(encoding); env->DeleteLocalRef(stringClass); return nullptr; }
    if (input.find('\0') != std::string::npos) {
        env->DeleteLocalRef(encoding); env->DeleteLocalRef(stringClass);
        fail(env, "Environment authority request contains NUL"); return nullptr;
    }
    // Exact-source native rebuilding is required before this becomes ready.
    // A stale core fails closed instead of reaching an unrelated old bridge.
    void *core = dlopen("libFloeAndroidLinuxAuthority.so", RTLD_NOW | RTLD_NOLOAD);
    auto exchange = core ? reinterpret_cast<Exchange>(dlsym(core, "floe_linux_authority_exchange")) : nullptr;
    auto release = core ? reinterpret_cast<Free>(dlsym(core, "floe_linux_authority_free")) : nullptr;
    if (!exchange || !release) {
        if (core) dlclose(core);
        env->DeleteLocalRef(encoding); env->DeleteLocalRef(stringClass);
        fail(env, "Environment authority unavailable in this native build"); return nullptr;
    }
    const char *response = exchange(input.c_str());
    if (!response) {
        dlclose(core);
        env->DeleteLocalRef(encoding); env->DeleteLocalRef(stringClass);
        fail(env, "Environment authority returned no response"); return nullptr;
    }
    const size_t responseLength = strnlen(response, limit + 1);
    jstring result = nullptr;
    if (responseLength <= limit) {
        jbyteArray output = env->NewByteArray(static_cast<jsize>(responseLength));
        if (output) {
            env->SetByteArrayRegion(output, 0, static_cast<jsize>(responseLength), reinterpret_cast<const jbyte *>(response));
            if (!env->ExceptionCheck()) result = static_cast<jstring>(env->NewObject(stringClass, constructor, output, encoding));
            env->DeleteLocalRef(output);
        }
    } else fail(env, "Environment authority response size invalid");
    release(response);
    dlclose(core);
    env->DeleteLocalRef(encoding); env->DeleteLocalRef(stringClass);
    return result;
}
