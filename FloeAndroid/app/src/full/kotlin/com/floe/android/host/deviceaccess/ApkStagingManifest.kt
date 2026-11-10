// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure manifest codec for App-staged APKs. Staging entries are host-issued:
 * the model can only name a `stagedId`, never a host path, and the manifest
 * keeps the bounded metadata the settings surface and the install tool show
 * (display name, byte size, content digest, archive package name when the
 * platform could read it). Tolerant parsing drops malformed entries so a
 * corrupted manifest can never mint an executable reference.
 */
internal object ApkStagingManifest {

    const val MAX_ENTRIES = 8
    const val MAX_FILE_NAME = 128
    const val MAX_SHA256 = 64

    /** Origins of a staged entry: manual SAF pick, task workspace transfer,
     *  or a user-granted file root copied by the privileged service. */
    object Origin {
        const val SAF = "saf"
        const val WORKSPACE = "workspace"
        const val FILE_ROOT = "fileRoot"
        val ALL: Set<String> = setOf(SAF, WORKSPACE, FILE_ROOT)

        fun valid(origin: String): Boolean = origin in ALL
    }

    data class Entry(
        val stagedId: String,
        val fileName: String,
        val sizeBytes: Long,
        val sha256: String,
        val packageName: String?,
        val addedAtMillis: Long,
        val origin: String = Origin.SAF,
    )

    /** Opaque host-issued staged id derived from the content digest. */
    fun stagedIdFor(sha256: String): String = "stage:" + sha256.take(16)

    fun stagedIdValid(stagedId: String): Boolean =
        stagedId.length in 8..64 && stagedId.all {
            it.isLetterOrDigit() || it == '_' || it == '-' || it == ':' || it == '.'
        }

    fun toJson(entries: List<Entry>): String {
        val array = JSONArray()
        for (entry in entries.take(MAX_ENTRIES)) {
            array.put(
                JSONObject()
                    .put("stagedId", entry.stagedId)
                    .put("fileName", entry.fileName)
                    .put("sizeBytes", entry.sizeBytes)
                    .put("sha256", entry.sha256)
                    .put("packageName", entry.packageName)
                    .put("addedAtMillis", entry.addedAtMillis)
                    .put("origin", entry.origin),
            )
        }
        return JSONObject().put("version", 1).put("entries", array).toString()
    }

    /** Tolerant parse: malformed entries are skipped, never fatal. */
    fun fromJson(raw: String?): List<Entry> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            val root = JSONObject(raw)
            if (root.optInt("version") != 1) return emptyList()
            val array = root.optJSONArray("entries") ?: return emptyList()
            val result = ArrayList<Entry>(minOf(array.length(), MAX_ENTRIES))
            for (index in 0 until minOf(array.length(), MAX_ENTRIES)) {
                val item = array.optJSONObject(index) ?: continue
                val sha = item.optString("sha256").take(MAX_SHA256)
                if (sha.length != 64) continue
                val stagedId = item.optString("stagedId").ifEmpty { stagedIdFor(sha) }
                if (!stagedIdValid(stagedId)) continue
                val fileName = item.optString("fileName").take(MAX_FILE_NAME)
                if (fileName.isBlank()) continue
                val size = item.optLong("sizeBytes", -1)
                if (size < 0) continue
                val packageName = item.optString("packageName").take(255)
                    .ifEmpty { null }
                val origin = item.optString("origin").take(16).ifEmpty { Origin.SAF }
                result.add(
                    Entry(
                        stagedId = stagedId,
                        fileName = fileName,
                        sizeBytes = size,
                        sha256 = sha,
                        packageName = packageName,
                        addedAtMillis = item.optLong("addedAtMillis", 0),
                        origin = if (Origin.valid(origin)) origin else Origin.SAF,
                    ),
                )
            }
            result
        } catch (_: Throwable) {
            emptyList()
        }
    }
}
