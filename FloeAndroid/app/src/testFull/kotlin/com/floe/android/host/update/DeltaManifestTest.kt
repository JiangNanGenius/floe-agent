// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Strict parsing of the release-bound `update-delta-v1.json`. A fed document is
 * untrusted input: every missing, malformed or out-of-bound field must yield
 * null (the caller then uses the full APK), never a partially-filled manifest.
 */
class DeltaManifestTest {

    private val sha = "a".repeat(64)

    private fun valid(): String = """
        {
          "schema": "floe.android.update.delta/1",
          "channel": "full-arm64-v8a",
          "package": "com.floe.agent.full",
          "releaseTag": "android/v0.1.0-alpha.17",
          "base": {
            "apkName": "Floe-Android-0.1.0-alpha.16-full-arm64-v8a.apk",
            "sha256": "${"b".repeat(64)}",
            "sizeBytes": 444671339,
            "versionName": "0.1.0-alpha.16",
            "versionCode": 18
          },
          "target": {
            "apkName": "Floe-Android-0.1.0-alpha.17-full-arm64-v8a.apk",
            "sha256": "$sha",
            "sizeBytes": 445796721,
            "versionName": "0.1.0-alpha.17",
            "versionCode": 19,
            "minSdk": 28,
            "abis": ["arm64-v8a"],
            "signerSha256": ["${"c".repeat(64)}"]
          },
          "patch": {
            "format": "floepatch",
            "version": 1,
            "assetName": "Floe-Android-0.1.0-alpha.17-from-0.1.0-alpha.16.delta",
            "sizeBytes": 143477820,
            "sha256": "${"d".repeat(64)}"
          }
        }
    """.trimIndent()

    @Test
    fun parsesTheProducerManifest() {
        val manifest = UpdateDeltaManifestParser.parse(valid())
        assertNotNull(manifest)
        requireNotNull(manifest)
        assertEquals(UpdateDeltaFormat.SCHEMA, manifest.schema)
        assertEquals(18L, manifest.base.versionCode)
        assertEquals(19L, manifest.target.versionCode)
        assertEquals(143477820L, manifest.patch.sizeBytes)
        assertEquals(listOf("arm64-v8a"), manifest.target.abis)
    }

    @Test
    fun rejectsUnknownSchema() {
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"schema\": \"floe.android.update.delta/1\"", "\"schema\": \"v2\"")))
    }

    @Test
    fun rejectsUppercaseOrShortHashes() {
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"sha256\": \"$sha\"", "\"sha256\": \"${"A".repeat(64)}\"")))
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"sha256\": \"$sha\"", "\"sha256\": \"abc\"")))
    }

    @Test
    fun rejectsUnsafePatchNames() {
        for (name in listOf("../escape.delta", "sub/dir.delta", "bad name.delta", "SHA256SUMS", "update-delta-v1.json")) {
            val text = valid().replace(
                "Floe-Android-0.1.0-alpha.17-from-0.1.0-alpha.16.delta",
                name,
            )
            assertNull("must reject $name", UpdateDeltaManifestParser.parse(text))
        }
    }

    @Test
    fun rejectsSizeAndVersionRegressions() {
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("445796721", "0")))
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"versionCode\": 18", "\"versionCode\": 0")))
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"minSdk\": 28", "\"minSdk\": 128")))
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"abis\": [\"arm64-v8a\"]", "\"abis\": []")))
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"signerSha256\": [\"${"c".repeat(64)}\"]", "\"signerSha256\": []")))
    }

    @Test
    fun rejectsOversizedDocuments() {
        val padded = valid() + " ".repeat((UpdateDeltaFormat.MAX_MANIFEST_BYTES + 1).toInt())
        assertNull(UpdateDeltaManifestParser.parse(padded))
    }

    @Test
    fun rejectsNonJsonAndMissingSections() {
        assertNull(UpdateDeltaManifestParser.parse("not json"))
        assertNull(UpdateDeltaManifestParser.parse("{}"))
        assertNull(UpdateDeltaManifestParser.parse(valid().replace("\"patch\": {", "\"patched\": {")))
    }
}
