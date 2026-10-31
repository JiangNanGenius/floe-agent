// SPDX-License-Identifier: Apache-2.0
// Public-SDK/native split verified by Main on android-37.0 android.jar and
// api-versions.xml (SSLSockets.exportKeyingMaterial since API 31). API 30 keeps
// the pinned upstream Conscrypt reflective exporter as an explicit, tested
// compatibility branch; it is never silently used on a missing class.
package moe.shizuku.pairing

import android.net.ssl.SSLSockets
import android.os.Build
import java.lang.reflect.InvocationTargetException
import javax.net.ssl.SSLSocket

fun interface KeyingMaterialExporter {
    fun export(socket: SSLSocket, label: String, context: ByteArray?, length: Int): ByteArray
}

object KeyingMaterialExporters {

    /** Exact ADB pairing label, including the trailing NUL as in upstream. */
    const val ADB_LABEL = "adb-label\u0000"
    const val ADB_LENGTH = 64
    const val MIN_LENGTH = 16
    const val MAX_LENGTH = 128

    fun adbPairingSupported(api: Int = Build.VERSION.SDK_INT): Boolean = api >= 30

    fun forDevice(api: Int = Build.VERSION.SDK_INT): KeyingMaterialExporter = when {
        api >= 31 -> PublicApiExporter
        api == 30 -> ConscryptLegacyExporter
        else -> UnsupportedExporter("pairing_requires_api30")
    }

    private object PublicApiExporter : KeyingMaterialExporter {
        override fun export(socket: SSLSocket, label: String, context: ByteArray?, length: Int): ByteArray {
            require(length in MIN_LENGTH..MAX_LENGTH) { "export length out of bounds" }
            if (!SSLSockets.isSupportedSocket(socket)) error("tls_exporter_unsupported_socket")
            return SSLSockets.exportKeyingMaterial(socket, label, context, length)
                ?: throw IllegalStateException("tls_exporter_null")
        }
    }

    private object ConscryptLegacyExporter : KeyingMaterialExporter {
        override fun export(socket: SSLSocket, label: String, context: ByteArray?, length: Int): ByteArray {
            require(length in MIN_LENGTH..MAX_LENGTH) { "export length out of bounds" }
            val classes = listOf("com.android.org.conscrypt.Conscrypt", "org.conscrypt.Conscrypt")
            for (name in classes) {
                try {
                    val type = Class.forName(name)
                    val method = type.getMethod(
                        "exportKeyingMaterial",
                        SSLSocket::class.java,
                        String::class.java,
                        ByteArray::class.java,
                        Int::class.javaPrimitiveType,
                    )
                    return method.invoke(null, socket, label, context, length) as ByteArray
                } catch (_: ClassNotFoundException) {
                    continue
                } catch (_: NoSuchMethodException) {
                    continue
                } catch (e: InvocationTargetException) {
                    throw IllegalStateException("tls_exporter_failed", e.cause)
                }
            }
            throw UnsupportedOperationException("api30_conscrypt_exporter_missing")
        }
    }

    private class UnsupportedExporter(private val reason: String) : KeyingMaterialExporter {
        override fun export(socket: SSLSocket, label: String, context: ByteArray?, length: Int): ByteArray =
            throw UnsupportedOperationException(reason)
    }
}
