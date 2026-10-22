// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.File
import java.io.IOException

/**
 * Provenance record written into the revision directory (NOT into rootfs/,
 * keeping the guest tree pure). Only a revision with a parseable manifest
 * and no installer ownership marker is considered fully prepared. This is
 * content provenance, not a registry row: FloeEnvironments remains the sole
 * authority that records which revision a project selects.
 */
data class RootfsManifest(
    val catalogId: String,
    val version: String,
    val displayName: String,
    val archiveFileName: String,
    val archiveUrl: String,
    val archiveSha256: String,
    val archiveBytes: Long,
    val installId: String,
    val createdAtEpochMs: Long,
    val stats: ExtractionStats,
) {
    fun toJson(): String = buildString {
        append('{')
        append("\"schema\":1,")
        append("\"catalogId\":\"").append(escape(catalogId)).append("\",")
        append("\"version\":\"").append(escape(version)).append("\",")
        append("\"displayName\":\"").append(escape(displayName)).append("\",")
        append("\"archiveFileName\":\"").append(escape(archiveFileName)).append("\",")
        append("\"archiveUrl\":\"").append(escape(archiveUrl)).append("\",")
        append("\"archiveSha256\":\"").append(escape(archiveSha256)).append("\",")
        append("\"archiveBytes\":").append(archiveBytes).append(',')
        append("\"installId\":\"").append(escape(installId)).append("\",")
        append("\"createdAtEpochMs\":").append(createdAtEpochMs).append(',')
        append("\"entries\":").append(stats.entries).append(',')
        append("\"files\":").append(stats.files).append(',')
        append("\"directories\":").append(stats.directories).append(',')
        append("\"symbolicLinks\":").append(stats.symbolicLinks).append(',')
        append("\"hardLinks\":").append(stats.hardLinks).append(',')
        append("\"excludedCharacterDevices\":").append(stats.excludedCharacterDevices).append(',')
        append("\"excludedBlockDevices\":").append(stats.excludedBlockDevices).append(',')
        append("\"excludedFifos\":").append(stats.excludedFifos).append(',')
        append("\"implicitDirectories\":").append(stats.implicitDirectories).append(',')
        append("\"extractedBytes\":").append(stats.bytesWritten).append(',')
        append("\"metadataRecords\":").append(stats.metadataRecords).append(',')
        append("\"mtimeFailures\":").append(stats.mtimeFailures)
        append("}\n")
    }

    companion object {
        /** Strict reader for the flat schema this installer writes. */
        fun parse(text: String): RootfsManifest {
            val body = text.trim()
            if (!body.startsWith("{") || !body.endsWith("}")) {
                throw RootfsInstallException(
                    InstallFailure.STAGING_INCOMPLETE, "manifest is not a JSON object",
                )
            }
            if (readLong(body, "schema") != 1L) {
                throw RootfsInstallException(
                    InstallFailure.STAGING_INCOMPLETE, "unsupported manifest schema",
                )
            }
            return RootfsManifest(
                catalogId = readString(body, "catalogId"),
                version = readString(body, "version"),
                displayName = readString(body, "displayName"),
                archiveFileName = readString(body, "archiveFileName"),
                archiveUrl = readString(body, "archiveUrl"),
                archiveSha256 = readString(body, "archiveSha256"),
                archiveBytes = readLong(body, "archiveBytes"),
                installId = readString(body, "installId"),
                createdAtEpochMs = readLong(body, "createdAtEpochMs"),
                stats = ExtractionStats(
                    entries = readLong(body, "entries"),
                    files = readLong(body, "files"),
                    directories = readLong(body, "directories"),
                    symbolicLinks = readLong(body, "symbolicLinks"),
                    hardLinks = readLong(body, "hardLinks"),
                    excludedCharacterDevices = readLong(body, "excludedCharacterDevices"),
                    excludedBlockDevices = readLong(body, "excludedBlockDevices"),
                    excludedFifos = readLong(body, "excludedFifos"),
                    metadataRecords = readLong(body, "metadataRecords"),
                    implicitDirectories = readLong(body, "implicitDirectories"),
                    bytesWritten = readLong(body, "extractedBytes"),
                    mtimeFailures = readLong(body, "mtimeFailures"),
                ),
            )
        }
    }
}

private fun escape(value: String): String = buildString {
    for (ch in value) {
        when (ch) {
            '\\' -> append("\\\\")
            '"' -> append("\\\"")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (ch < ' ') append("\\u00")
                .append(Integer.toHexString(ch.code).padStart(2, '0')) else append(ch)
        }
    }
}

private fun manifestCorrupt(detail: String) =
    RootfsInstallException(InstallFailure.STAGING_INCOMPLETE, detail)

private fun readString(body: String, key: String): String {
    val marker = "\"" + key + "\":\""
    val start = body.indexOf(marker)
    if (start < 0) throw manifestCorrupt("missing field $key")
    var index = start + marker.length
    val out = StringBuilder()
    while (index < body.length) {
        val ch = body[index]
        when (ch) {
            '"' -> return out.toString()
            '\\' -> {
                val next = body.getOrNull(index + 1) ?: throw manifestCorrupt("bad escape")
                out.append(
                    when (next) {
                        '"' -> '"'
                        '\\' -> '\\'
                        'n' -> '\n'
                        'r' -> '\r'
                        't' -> '\t'
                        'u' -> {
                            val hex = body.substring(index + 2, minOf(index + 6, body.length))
                            val code = hex.toIntOrNull(16) ?: throw manifestCorrupt("bad \\u in $key")
                            index += 4
                            code.toChar()
                        }
                        else -> throw manifestCorrupt("unknown escape in $key")
                    },
                )
                index += 1
            }
            else -> out.append(ch)
        }
        index += 1
    }
    throw manifestCorrupt("unterminated field $key")
}

private fun readLong(body: String, key: String): Long {
    val marker = "\"" + key + "\":"
    val start = body.indexOf(marker)
    if (start < 0) throw manifestCorrupt("missing numeric field $key")
    var index = start + marker.length
    val digits = StringBuilder()
    while (index < body.length && (body[index].isDigit() || body[index] == '-')) {
        digits.append(body[index])
        index += 1
    }
    return digits.toString().toLongOrNull()
        ?: throw manifestCorrupt("bad numeric value for $key")
}
