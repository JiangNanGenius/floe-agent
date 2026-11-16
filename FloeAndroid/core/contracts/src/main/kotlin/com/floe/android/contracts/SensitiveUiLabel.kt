// SPDX-License-Identifier: MPL-2.0
package com.floe.android.contracts

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Installation-local key. Its bytes must never be logged, backed up or model-visible. */
class SensitiveUiLabelKey private constructor(private val bytes: ByteArray) {
    fun copyBytes(): ByteArray = bytes.copyOf()
    override fun toString(): String = "SensitiveUiLabelKey(<redacted>)"
    override fun equals(other: Any?): Boolean = other is SensitiveUiLabelKey &&
        MessageDigest.isEqual(bytes, other.bytes)
    override fun hashCode(): Int = bytes.contentHashCode()

    companion object {
        fun fromBytes(bytes: ByteArray): SensitiveUiLabelKey? =
            if (bytes.size == 32) SensitiveUiLabelKey(bytes.copyOf()) else null
    }
}

data class SensitiveUiLabelIdentity(
    val packageName: String, val windowId: Int, val displayId: Int,
    val path: List<Int>, val className: String, val viewId: String?,
) {
    fun isWellFormed(): Boolean = packageName.isNotBlank() && packageName.length <= 255 &&
        className.isNotBlank() && className.length <= 255 && windowId >= 0 && displayId >= 0 &&
        path.size <= 32 && path.all { it in 0..4096 } && (viewId == null || viewId.length <= 255)
}

data class SensitiveUiLabelBaseline(
    val identity: SensitiveUiLabelIdentity,
    /** Null for the button itself; otherwise the actual direct parent button. */
    val safeParent: SensitiveUiLabelIdentity?,
    val digest: String,
) {
    fun isWellFormed(): Boolean = identity.isWellFormed() && digest.length == 64 &&
        digest.all { it in '0'..'9' || it in 'a'..'f' } &&
        (safeParent == null || (safeParent.isWellFormed() &&
            safeParent.packageName == identity.packageName && safeParent.windowId == identity.windowId &&
            safeParent.displayId == identity.displayId && identity.path.isNotEmpty() &&
            identity.path.dropLast(1) == safeParent.path))
}

/** Exact, unnormalised, complete fields only. No hint or truncated text is accepted. */
object SensitiveUiLabelFingerprint {
    const val MAX_FIELD_CHARS = 2000
    fun hmac(key: SensitiveUiLabelKey, text: String?, description: String?): String? {
        val fields = listOf(text, description)
        if (fields.any { it != null && (it.length > MAX_FIELD_CHARS || !validUtf16(it)) }) return null
        val mac = Mac.getInstance("HmacSHA256")
        val bytes = key.copyBytes()
        try { mac.init(SecretKeySpec(bytes, "HmacSHA256")) } finally { bytes.fill(0) }
        for (field in fields) {
            val encoded = field?.toByteArray(Charsets.UTF_8)
            val length = encoded?.size ?: -1
            mac.update(byteArrayOf((length ushr 24).toByte(), (length ushr 16).toByte(),
                (length ushr 8).toByte(), length.toByte()))
            if (encoded != null) mac.update(encoded)
        }
        return mac.doFinal().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun validUtf16(value: String): Boolean {
        var i = 0
        while (i < value.length) {
            val c = value[i++]
            if (Character.isHighSurrogate(c)) {
                if (i >= value.length || !Character.isLowSurrogate(value[i++])) return false
            } else if (Character.isLowSurrogate(c)) return false
        }
        return true
    }
}
