// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.fonts

import java.io.File
import java.io.RandomAccessFile

/** Bounded SFNT metadata only; actual Android Typeface admission is mandatory. */
internal object SfntMetadata {
    const val MAX_BYTES = 32L * 1024 * 1024
    data class FaceNames(val displayName: String, val aliases: List<String>)
    fun faceNames(file: File): List<String> = metadata(file).map { it.displayName }
    fun metadata(file: File): List<FaceNames> = RandomAccessFile(file, "r").use { f ->
        val size = f.length()
        require(size in 12..MAX_BYTES) { "Invalid font size" }
        fun at(offset: Long, count: Long) {
            require(offset >= 0 && count >= 0 && offset <= size - count) { "Invalid font table" }
            f.seek(offset)
        }
        fun uint(): Long = f.readInt().toLong() and 0xffffffffL
        at(0, 12)
        val signature = f.readInt()
        val offsets = if (signature == 0x74746366) {
            val version = f.readInt()
            require(version == 0x00010000 || version == 0x00020000) { "Invalid font collection" }
            val count = uint()
            require(count in 1..32) { "Too many font faces" }
            at(12, count * 4)
            List(count.toInt()) { uint() }
        } else listOf(0L)
        offsets.mapIndexed { index, offset ->
            at(offset, 12)
            require(f.readInt() in setOf(0x00010000, 0x4f54544f, 0x74727565)) { "Unsupported font" }
            val count = f.readUnsignedShort()
            require(count in 1..256) { "Invalid font table count" }
            at(offset + 12, count * 16L)
            var nameOffset: Long? = null
            var nameSize = 0L
            repeat(count) {
                val tag = f.readInt(); f.readInt()
                val start = uint(); val bytes = uint()
                require(start <= size && bytes <= size - start) { "Font table escapes file" }
                if (tag == 0x6e616d65) { nameOffset = start; nameSize = bytes }
            }
            val base = nameOffset ?: error("Font names missing")
            require(nameSize in 6..1048576) { "Invalid font names" }
            at(base, 6)
            require(f.readUnsignedShort() in 0..1) { "Invalid name table" }
            val records = f.readUnsignedShort()
            val strings = f.readUnsignedShort()
            require(records <= 2048 && 6 + records * 12L <= nameSize && strings.toLong() <= nameSize) { "Invalid name records" }
            var best: Pair<Int, String>? = null
            val aliases = linkedSetOf<String>()
            repeat(records) { record ->
                at(base + 6 + record * 12L, 12)
                val platform = f.readUnsignedShort(); val encoding = f.readUnsignedShort()
                val language = f.readUnsignedShort(); val id = f.readUnsignedShort()
                val length = f.readUnsignedShort(); val start = f.readUnsignedShort()
                require(strings + start + length.toLong() <= nameSize) { "Invalid font name range" }
                if (id in setOf(1, 4, 6, 16) && length in 1..1024 &&
                    (platform == 0 || platform == 3 && encoding in setOf(0, 1, 10))) {
                    at(base + strings + start, length.toLong())
                    val bytes = ByteArray(length); f.readFully(bytes)
                    val text = String(bytes, Charsets.UTF_16BE).filter { !it.isISOControl() }.trim().take(160)
                    if (text.isNotBlank() && aliases.size < 32) aliases.add(text)
                    val rank = (if (id == 4) 4 else if (id == 16) 2 else if (id == 1) 0 else -2) +
                        (if (language == 0x409) 1 else 0)
                    if (text.isNotBlank() && (best == null || rank > best!!.first)) best = rank to text
                }
            }
            FaceNames(best?.second ?: "Font ${index + 1}", aliases.toList())
        }
    }
}
