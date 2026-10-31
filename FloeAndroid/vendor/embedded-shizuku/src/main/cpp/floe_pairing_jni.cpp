// SPDX-License-Identifier: Apache-2.0
// Adapted from RikkaApps/Shizuku manager/src/main/jni/adb_pairing.cpp at
// b844bc491f1790c72328e1a8e5b2349f8978f0ea.
//
// Modification record for Floe:
//  - JNI class renamed to moe.shizuku.pairing.NativePairingContext;
//  - password/peer buffers are released with JNI_ABORT after use where possible;
//  - all protocol lengths are bounded before allocation, including the AEAD path;
//  - diagnostics never include pairing codes, key material, peer-info bytes or
//    decrypted plaintext;
//  - sequence counters refuse to wrap instead of reusing a nonce;
//  - the BoringSSL SPAKE2/HKDF/AES-128-GCM construction is otherwise unchanged.
#include <jni.h>
#include <cstring>
#include <cstdlib>
#include <cinttypes>
#include <cstdint>
#include <openssl/curve25519.h>
#include <openssl/hkdf.h>
#include <openssl/evp.h>

#define LOG_TAG "FloeAdbPairing"
#include "upstream/logging.h"

namespace {

constexpr spake2_role_t kClientRole = spake2_role_alice;
constexpr spake2_role_t kServerRole = spake2_role_bob;

const uint8_t kClientName[] = "adb pair client";
const uint8_t kServerName[] = "adb pair server";

constexpr size_t kHkdfKeyLength = 16;
constexpr size_t kMaxPasswordSize = 256;
constexpr size_t kMaxInputSize = 64 * 1024;

struct PairingContextNative {
    SPAKE2_CTX *spake2_ctx;
    uint8_t key[SPAKE2_MAX_MSG_SIZE];
    size_t key_size;

    EVP_AEAD_CTX *aes_ctx;
    uint64_t dec_sequence;
    uint64_t enc_sequence;
};

jlong PairingContext_Constructor(JNIEnv *env, jclass, jboolean isClient, jbyteArray jPassword) {
    if (jPassword == nullptr) return 0;
    jsize password_size = env->GetArrayLength(jPassword);
    if (password_size <= 0 || static_cast<size_t>(password_size) > kMaxPasswordSize) return 0;

    spake2_role_t role;
    const uint8_t *my_name;
    const uint8_t *their_name;
    size_t my_len;
    size_t their_len;
    if (isClient) {
        role = kClientRole;
        my_name = kClientName;
        my_len = sizeof(kClientName);
        their_name = kServerName;
        their_len = sizeof(kServerName);
    } else {
        role = kServerRole;
        my_name = kServerName;
        my_len = sizeof(kServerName);
        their_name = kClientName;
        their_len = sizeof(kClientName);
    }

    auto *spake2_ctx = SPAKE2_CTX_new(role, my_name, my_len, their_name, their_len);
    if (spake2_ctx == nullptr) {
        LOGE("unable to create SPAKE2 context");
        return 0;
    }

    auto *password = env->GetByteArrayElements(jPassword, nullptr);
    if (password == nullptr) {
        SPAKE2_CTX_free(spake2_ctx);
        return 0;
    }

    uint8_t key[SPAKE2_MAX_MSG_SIZE];
    size_t key_size = 0;
    int status = SPAKE2_generate_msg(spake2_ctx, key, &key_size, sizeof(key),
                                     reinterpret_cast<uint8_t *>(password),
                                     static_cast<size_t>(password_size));
    memset(password, 0, static_cast<size_t>(password_size));
    env->ReleaseByteArrayElements(jPassword, password, JNI_ABORT);
    if (status != 1 || key_size == 0 || key_size > sizeof(key)) {
        LOGE("unable to generate SPAKE2 message");
        SPAKE2_CTX_free(spake2_ctx);
        return 0;
    }

    auto *ctx = static_cast<PairingContextNative *>(calloc(1, sizeof(PairingContextNative)));
    if (ctx == nullptr) {
        SPAKE2_CTX_free(spake2_ctx);
        return 0;
    }
    ctx->spake2_ctx = spake2_ctx;
    memcpy(ctx->key, key, key_size);
    ctx->key_size = key_size;
    memset(key, 0, sizeof(key));
    return reinterpret_cast<jlong>(ctx);
}

jbyteArray PairingContext_Msg(JNIEnv *env, jobject, jlong ptr) {
    auto *ctx = reinterpret_cast<PairingContextNative *>(ptr);
    if (ctx == nullptr || ctx->key_size == 0 || ctx->key_size > SPAKE2_MAX_MSG_SIZE) return nullptr;
    jbyteArray message = env->NewByteArray(static_cast<jsize>(ctx->key_size));
    if (message == nullptr) return nullptr;
    env->SetByteArrayRegion(message, 0, static_cast<jsize>(ctx->key_size),
                            reinterpret_cast<jbyte *>(ctx->key));
    return message;
}

jboolean PairingContext_InitCipher(JNIEnv *env, jobject, jlong ptr, jbyteArray jTheirMessage) {
    auto *ctx = reinterpret_cast<PairingContextNative *>(ptr);
    if (ctx == nullptr || ctx->spake2_ctx == nullptr || jTheirMessage == nullptr) return JNI_FALSE;
    jsize their_size = env->GetArrayLength(jTheirMessage);
    if (their_size <= 0 || static_cast<size_t>(their_size) > SPAKE2_MAX_MSG_SIZE) {
        LOGE("invalid peer SPAKE2 message size");
        return JNI_FALSE;
    }

    auto *their_message = env->GetByteArrayElements(jTheirMessage, nullptr);
    if (their_message == nullptr) return JNI_FALSE;

    uint8_t key_material[SPAKE2_MAX_KEY_SIZE];
    size_t key_material_size = 0;
    int status = SPAKE2_process_msg(ctx->spake2_ctx, key_material, &key_material_size,
                                    sizeof(key_material),
                                    reinterpret_cast<uint8_t *>(their_message),
                                    static_cast<size_t>(their_size));
    env->ReleaseByteArrayElements(jTheirMessage, their_message, JNI_ABORT);
    if (status != 1 || key_material_size == 0) {
        LOGE("SPAKE2 peer verification failed");
        return JNI_FALSE;
    }

    uint8_t key[kHkdfKeyLength];
    const char info[] = "adb pairing_auth aes-128-gcm key";
    status = HKDF(key, sizeof(key), EVP_sha256(), key_material, key_material_size,
                  nullptr, 0, reinterpret_cast<const uint8_t *>(info), sizeof(info) - 1);
    memset(key_material, 0, sizeof(key_material));
    if (status != 1) {
        LOGE("HKDF failed");
        return JNI_FALSE;
    }

    ctx->aes_ctx = EVP_AEAD_CTX_new(EVP_aead_aes_128_gcm(), key, sizeof(key),
                                    EVP_AEAD_DEFAULT_TAG_LENGTH);
    memset(key, 0, sizeof(key));
    if (ctx->aes_ctx == nullptr) {
        LOGE("unable to initialise AEAD context");
        return JNI_FALSE;
    }
    return JNI_TRUE;
}

jbyteArray PairingContext_Encrypt(JNIEnv *env, jobject, jlong ptr, jbyteArray jInput) {
    auto *ctx = reinterpret_cast<PairingContextNative *>(ptr);
    if (ctx == nullptr || ctx->aes_ctx == nullptr || jInput == nullptr) return nullptr;
    jsize input_size = env->GetArrayLength(jInput);
    if (input_size <= 0 || static_cast<size_t>(input_size) > kMaxInputSize) return nullptr;
    if (ctx->enc_sequence == UINT64_MAX) return nullptr;

    size_t output_capacity = static_cast<size_t>(input_size) +
                             EVP_AEAD_max_overhead(EVP_AEAD_CTX_aead(ctx->aes_ctx));
    auto *output = static_cast<uint8_t *>(malloc(output_capacity));
    if (output == nullptr) return nullptr;
    auto *input = env->GetByteArrayElements(jInput, nullptr);
    if (input == nullptr) {
        free(output);
        return nullptr;
    }

    size_t nonce_size = EVP_AEAD_nonce_length(EVP_AEAD_CTX_aead(ctx->aes_ctx));
    uint8_t nonce[EVP_AEAD_MAX_NONCE_LENGTH];
    if (nonce_size > sizeof(nonce)) {
        free(output);
        env->ReleaseByteArrayElements(jInput, input, JNI_ABORT);
        return nullptr;
    }
    memset(nonce, 0, sizeof(nonce));
    memcpy(nonce, &ctx->enc_sequence, sizeof(ctx->enc_sequence));

    size_t written = 0;
    int status = EVP_AEAD_CTX_seal(ctx->aes_ctx, output, &written, output_capacity,
                                   nonce, nonce_size,
                                   reinterpret_cast<uint8_t *>(input),
                                   static_cast<size_t>(input_size), nullptr, 0);
    env->ReleaseByteArrayElements(jInput, input, JNI_ABORT);
    if (!status) {
        LOGE("AEAD seal failed");
        free(output);
        return nullptr;
    }
    ctx->enc_sequence++;

    jbyteArray result = env->NewByteArray(static_cast<jsize>(written));
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(written),
                                reinterpret_cast<jbyte *>(output));
    }
    free(output);
    return result;
}

jbyteArray PairingContext_Decrypt(JNIEnv *env, jobject, jlong ptr, jbyteArray jInput) {
    auto *ctx = reinterpret_cast<PairingContextNative *>(ptr);
    if (ctx == nullptr || ctx->aes_ctx == nullptr || jInput == nullptr) return nullptr;
    jsize input_size = env->GetArrayLength(jInput);
    if (input_size <= 0 || static_cast<size_t>(input_size) > kMaxInputSize) return nullptr;
    if (ctx->dec_sequence == UINT64_MAX) return nullptr;

    auto *output = static_cast<uint8_t *>(malloc(static_cast<size_t>(input_size)));
    if (output == nullptr) return nullptr;
    auto *input = env->GetByteArrayElements(jInput, nullptr);
    if (input == nullptr) {
        free(output);
        return nullptr;
    }

    size_t nonce_size = EVP_AEAD_nonce_length(EVP_AEAD_CTX_aead(ctx->aes_ctx));
    uint8_t nonce[EVP_AEAD_MAX_NONCE_LENGTH];
    if (nonce_size > sizeof(nonce)) {
        free(output);
        env->ReleaseByteArrayElements(jInput, input, JNI_ABORT);
        return nullptr;
    }
    memset(nonce, 0, sizeof(nonce));
    memcpy(nonce, &ctx->dec_sequence, sizeof(ctx->dec_sequence));

    size_t written = 0;
    int status = EVP_AEAD_CTX_open(ctx->aes_ctx, output, &written,
                                   static_cast<size_t>(input_size),
                                   nonce, nonce_size,
                                   reinterpret_cast<uint8_t *>(input),
                                   static_cast<size_t>(input_size), nullptr, 0);
    env->ReleaseByteArrayElements(jInput, input, JNI_ABORT);
    if (!status) {
        free(output);
        return nullptr;
    }
    ctx->dec_sequence++;

    jbyteArray result = env->NewByteArray(static_cast<jsize>(written));
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(written),
                                reinterpret_cast<jbyte *>(output));
    }
    free(output);
    return result;
}

void PairingContext_Destroy(JNIEnv *, jobject, jlong ptr) {
    auto *ctx = reinterpret_cast<PairingContextNative *>(ptr);
    if (ctx == nullptr) return;
    if (ctx->spake2_ctx != nullptr) SPAKE2_CTX_free(ctx->spake2_ctx);
    if (ctx->aes_ctx != nullptr) EVP_AEAD_CTX_free(ctx->aes_ctx);
    memset(ctx, 0, sizeof(PairingContextNative));
    free(ctx);
}

} // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return -1;

    JNINativeMethod methods[] = {
            {"nativeConstructor", "(Z[B)J",  reinterpret_cast<void *>(PairingContext_Constructor)},
            {"nativeMsg",         "(J)[B",   reinterpret_cast<void *>(PairingContext_Msg)},
            {"nativeInitCipher",  "(J[B)Z",  reinterpret_cast<void *>(PairingContext_InitCipher)},
            {"nativeEncrypt",     "(J[B)[B", reinterpret_cast<void *>(PairingContext_Encrypt)},
            {"nativeDecrypt",     "(J[B)[B", reinterpret_cast<void *>(PairingContext_Decrypt)},
            {"nativeDestroy",     "(J)V",    reinterpret_cast<void *>(PairingContext_Destroy)},
    };

    jclass type = env->FindClass("moe/shizuku/pairing/NativePairingContext");
    if (type == nullptr) return -1;
    if (env->RegisterNatives(type, methods, sizeof(methods) / sizeof(JNINativeMethod)) != 0) {
        return -1;
    }
    return JNI_VERSION_1_6;
}
