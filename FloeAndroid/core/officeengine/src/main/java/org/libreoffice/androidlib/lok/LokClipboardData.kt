/* -*- tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * Floe G05-R1 clipboard model bridge.
 *
 * Required shape by the prebuilt libandroidapp.so (androidapp.cpp:364-370,
 * 445-450): FindClass("org/libreoffice/androidlib/lok/LokClipboardEntry") with
 * a no-arg <init>()V and fields mime:Ljava/lang/String; and data:[B; plus a
 * LokClipboardData class exposing the field clipboardEntries:Ljava/util/ArrayList;.
 * Field/method identities are JNI-resolved, so they are fixed. The file
 * serialization below replaces upstream's private format and only needs to be
 * self-consistent (App-instance-scoped cache for cross-session paste).
 */
package org.libreoffice.androidlib.lok

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.charset.StandardCharsets

class LokClipboardEntry {
    @JvmField
    var mime: String? = null

    @JvmField
    var data: ByteArray? = null
}

class LokClipboardData {
    @JvmField
    val clipboardEntries: ArrayList<LokClipboardEntry> = ArrayList()

    private fun firstText(mimeType: String): String? =
        clipboardEntries.firstOrNull { it.mime == mimeType }?.data?.toString(StandardCharsets.UTF_8)

    fun getText(): String? =
        firstText("text/plain;charset=utf-8") ?: firstText("text/plain")

    fun getHtml(): String? = firstText("text/html")

    fun writeToFile(file: File) {
        DataOutputStream(file.outputStream().buffered()).use { out ->
            out.writeInt(clipboardEntries.size)
            for (entry in clipboardEntries) {
                val mime = entry.mime.orEmpty().toByteArray(StandardCharsets.UTF_8)
                out.writeInt(mime.size)
                out.write(mime)
                val data = entry.data ?: ByteArray(0)
                out.writeInt(data.size)
                out.write(data)
            }
        }
    }

    companion object {
        @JvmStatic
        fun createFromFile(file: File): LokClipboardData? {
            return try {
                DataInputStream(file.inputStream().buffered()).useWith { input ->
                    val count = input.readInt()
                    if (count < 0 || count > 4096) return@useWith null
                    val data = LokClipboardData()
                    for (i in 0 until count) {
                        val mimeLen = input.readInt()
                        if (mimeLen < 0 || mimeLen > 4096) return@useWith null
                        val mime = ByteArray(mimeLen)
                        input.readFully(mime)
                        val dataLen = input.readInt()
                        if (dataLen < 0 || dataLen > 32 * 1024 * 1024) return@useWith null
                        val bytes = ByteArray(dataLen)
                        input.readFully(bytes)
                        data.clipboardEntries.add(
                            LokClipboardEntry().apply {
                                this.mime = String(mime, StandardCharsets.UTF_8)
                                this.data = bytes
                            },
                        )
                    }
                    data
                }
            } catch (e: Exception) {
                null
            }
        }

        private inline fun <T> java.io.Closeable.useWith(block: (java.io.DataInputStream) -> T): T {
            (this as java.io.DataInputStream).use { return block(it) }
        }
    }
}
