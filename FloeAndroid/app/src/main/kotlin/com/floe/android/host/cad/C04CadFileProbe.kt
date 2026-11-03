// SPDX-License-Identifier: MPL-2.0
//
// Cheap format proof before a reader is started. It is intentionally only a
// hint/guard: every accepted file is still parsed by the pinned DXF/OCCT/mesh
// reader, and a reader failure is typed. Formats whose containers are text or
// ambiguous (OBJ/STL/IGES/BREP) are left to those readers instead of being
// rejected by a guessed magic check.
package com.floe.android.host.cad

import java.io.File
import java.io.FileInputStream
import java.util.Locale

internal object C04CadFileProbe {
    fun verify(format: C04CadFormat, file: File): String? {
        if (!file.isFile || file.length() <= 0) return "empty"
        val prefix = readPrefix(file, 4096) ?: return "unreadable"
        val text = String(prefix, Charsets.ISO_8859_1)
        return when (format) {
            C04CadFormat.DWG -> {
                val header = String(prefix, 0, minOf(6, prefix.size), Charsets.US_ASCII)
                if (!header.startsWith("AC10")) "invalidDwg" else null
            }
            C04CadFormat.DXF -> {
                if (!text.contains("SECTION") &&
                    !text.startsWith("AutoCAD Binary DXF")
                ) "invalidDxf" else null
            }
            C04CadFormat.GLB -> {
                if (prefix.size < 12 ||
                    text.substring(0, 4) != "glTF" ||
                    readUInt32LE(prefix, 4) != 2u
                ) "invalidGlb" else null
            }
            C04CadFormat.GLTF -> {
                if (!text.trimStart().startsWith("{")) "invalidGltf" else null
            }
            C04CadFormat.THREE_MF -> {
                if (prefix.size < 4 ||
                    prefix[0] != 'P'.code.toByte() || prefix[1] != 'K'.code.toByte() ||
                    prefix[2] != 3.toByte() || prefix[3] != 4.toByte()
                ) "invalid3mf" else null
            }
            C04CadFormat.STEP, C04CadFormat.STP -> {
                if (!text.contains("ISO-10303-21")) "invalidStep" else null
            }
            C04CadFormat.IGES, C04CadFormat.IGS,
            C04CadFormat.BREP, C04CadFormat.OBJ, C04CadFormat.STL,
            C04CadFormat.FLOECAD -> null // directory package, proved by its manifest
        }
    }

    private fun readPrefix(file: File, maximum: Int): ByteArray? {
        return try {
            FileInputStream(file).use { input ->
                val buffer = ByteArray(maximum)
                val read = input.read(buffer)
                if (read <= 0) null else buffer.copyOf(read)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun readUInt32LE(bytes: ByteArray, offset: Int): UInt =
        (bytes[offset].toUInt() and 0xFFu) or
            ((bytes[offset + 1].toUInt() and 0xFFu) shl 8) or
            ((bytes[offset + 2].toUInt() and 0xFFu) shl 16) or
            ((bytes[offset + 3].toUInt() and 0xFFu) shl 24)
}
