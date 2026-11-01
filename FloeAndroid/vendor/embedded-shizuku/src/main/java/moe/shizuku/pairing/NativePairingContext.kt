// SPDX-License-Identifier: Apache-2.0
// Adapted from RikkaApps/Shizuku manager/src/main/jni/adb_pairing.cpp at
// b844bc491f1790c72328e1a8e5b2349f8978f0ea. The native implementation remains
// the pinned BoringSSL SPAKE2 + HKDF + AES-128-GCM path; this Kotlin side only
// renames the JNI class, bounds inputs and never logs password material.
package moe.shizuku.pairing

import java.io.Closeable

internal class NativePairingContext private constructor(private var pointer: Long) : Closeable {

    val message: ByteArray
        get() = nativeMsg(pointer)

    fun initCipher(theirMessage: ByteArray): Boolean =
        nativeInitCipher(pointer, theirMessage)

    fun encrypt(plain: ByteArray): ByteArray? = nativeEncrypt(pointer, plain)

    fun decrypt(cipher: ByteArray): ByteArray? = nativeDecrypt(pointer, cipher)

    override fun close() {
        if (pointer != 0L) {
            nativeDestroy(pointer)
            pointer = 0L
        }
    }

    private external fun nativeMsg(nativePtr: Long): ByteArray
    private external fun nativeInitCipher(nativePtr: Long, theirMessage: ByteArray): Boolean
    private external fun nativeEncrypt(nativePtr: Long, plain: ByteArray): ByteArray?
    private external fun nativeDecrypt(nativePtr: Long, cipher: ByteArray): ByteArray?
    private external fun nativeDestroy(nativePtr: Long)

    companion object {
        init {
            System.loadLibrary("floe_adb_pairing")
        }

        fun create(password: ByteArray): NativePairingContext? {
            if (password.isEmpty() || password.size > 256) return null
            val pointer = nativeConstructor(true, password)
            return if (pointer != 0L) NativePairingContext(pointer) else null
        }

        @JvmStatic
        private external fun nativeConstructor(isClient: Boolean, password: ByteArray): Long
    }
}
