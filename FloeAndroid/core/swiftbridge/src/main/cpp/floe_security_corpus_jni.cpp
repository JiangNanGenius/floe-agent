// SPDX-License-Identifier: MPL-2.0
//
// Trusted security-corpus handoff — JNI adapter (NEW additive translation
// unit inside the EXISTING floe_jni target). The frozen floe_jni.cpp, the
// published floe_secret_jni.cpp, floe_runtime_jni.cpp and
// floe_attachment_staging_jni.cpp stay byte-identical.
//
// This is NOT a bridge command: the App bootstrap reads the packaged
// `security/catastrophic-patterns.json` asset and freezes those bytes into
// the native Root BEFORE the Root start, so the production RunIngressContext
// carries the REAL trusted corpus. The Swift `_cdecl` validates with the
// ORIGINAL loader (pinned SHA-256, <=1 MiB, same Codable schema, non-empty
// pattern list, same regex compile path); a missing/tampered/empty corpus
// never freezes and ordinary runs keep their truthful `corpusAbsent`
// refusal before any model/store effect.
//
// Discipline (mirrors the reviewed runtime TU):
//  * no global refs, no AttachCurrentThread, no Swift -> JVM callback;
//  * typed status returned as jint (0 ok / 1 idempotent / negative refusal);
//    the corpus bytes and their digest never enter an exception message;
//  * hard byte bound checked BEFORE copying the array.
#include <jni.h>

#include <cstdint>

extern "C" {
// G02SecurityCorpus.swift — trusted host bootstrap seam (additive symbol).
int32_t floe_security_corpus_freeze(const uint8_t *bytes, int32_t length);
}

namespace {

// Mirrors AndroidCatastrophicCorpus.maximumCorpusBytes (QualificationSeam).
constexpr int32_t kMaximumCorpusBytes = 1 * 1024 * 1024;

}  // namespace

// Freeze the trusted corpus bytes read by the host from the packaged asset.
// Anything but 0/1 means "not frozen": the caller reports it honestly and
// the run gate keeps its typed corpusAbsent refusal; never a fabricated gate.
extern "C" JNIEXPORT jint JNICALL
Java_com_floe_android_bridge_SecurityCorpusNative_securityCorpusFreeze(
    JNIEnv *env, jobject, jbyteArray corpusBytes) {
    if (!env) return -499;
    if (!corpusBytes) return -105;  // invalidArguments
    const jsize length = env->GetArrayLength(corpusBytes);
    if (length < 0) return -105;
    if (length == 0) return -421;                  // empty
    if (length > kMaximumCorpusBytes) return -422; // oversized (no copy)
    jboolean isCopy = JNI_FALSE;
    const jbyte *bytes = env->GetByteArrayElements(corpusBytes, &isCopy);
    if (!bytes) {
        if (env->ExceptionCheck()) env->ExceptionClear();
        return -499;  // internal
    }
    const int32_t status = floe_security_corpus_freeze(
        reinterpret_cast<const uint8_t *>(bytes), static_cast<int32_t>(length));
    env->ReleaseByteArrayElements(corpusBytes, const_cast<jbyte *>(bytes),
                                  JNI_ABORT);
    return status;
}
