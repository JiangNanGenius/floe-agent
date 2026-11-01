// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import com.floe.android.core.networkcapture.CaptureAnalysisPublisher
import com.floe.android.core.networkcapture.CaptureArtifactStore
import com.floe.android.core.networkcapture.CaptureMode
import com.floe.android.core.networkcapture.CaptureOwner
import com.floe.android.core.networkcapture.CapturePhase
import com.floe.android.core.networkcapture.CaptureState
import com.floe.android.core.networkcapture.PcapFormatCheck
import com.floe.android.core.networkcapture.PcapLinkType
import com.floe.android.core.pcap.PcapAnalysisStore
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureArtifactStoreTest {

    private val root: File = Files.createTempDirectory("floe-capture-test").toFile()
    private val owner = CaptureOwner(ownerId = "capture-test", nativeEpoch = 3)

    @After
    fun cleanup() {
        root.deleteRecursively()
    }

    private fun packet(): ByteArray = byteArrayOf(
        0x45, 0x00, 0x00, 0x14,
        0x00, 0x00, 0x00, 0x00,
        0x40, 0xFD.toByte(), 0x00, 0x00,
        0x0A, 0x00, 0x00, 0x01,
        0x0A, 0x00, 0x00, 0x02,
    )

    @Test
    fun finalizesCompleteCaptureAndPublishesBoundedAnalysis() {
        val store = CaptureArtifactStore(root)
        val sessionId = UUID.randomUUID().toString()
        val artifact = store.begin(
            sessionId = sessionId,
            owner = owner,
            mode = CaptureMode.VPN,
            detailed = false,
            maxBytes = 1_000_000,
            maxPackets = 100,
            maxDurationMillis = 60_000,
        )
        artifact.sink.start()
        assertTrue(artifact.sink.offer(packet(), 0, 20))
        val sink = artifact.sink.closeAndDrain(5_000)
        assertTrue(sink.drained)
        val result = store.finalize(
            artifact = artifact,
            sink = sink,
            state = CaptureState(
                sessionId = sessionId,
                owner = owner,
                mode = CaptureMode.VPN,
                phase = CapturePhase.FINALIZING,
            ),
            startedAtMillis = 1L,
            endedAtMillis = 2L,
            limitations = listOf("encrypted traffic remains encrypted"),
        )
        assertFalse(result.partial)
        assertEquals("capture-$sessionId.pcap", result.file.name)
        assertTrue(PcapFormatCheck.isValidGlobalHeader(result.file.readBytes()))
        assertEquals(24 + 16 + 20, result.bytes.toInt())
        val manifest = JSONObject(result.manifestFile.readText())
        assertTrue(manifest.getBoolean("complete"))
        assertEquals(PcapLinkType.RAW.value, result.file.readBytes()[20].toInt() and 0xFF)
        assertEquals(sessionId, manifest.getString("sessionId"))

        val analysisStore = PcapAnalysisStore(File(root, "analysis"))
        val published = CaptureAnalysisPublisher(analysisStore).publish(
            owner = owner,
            result = result,
            detailed = false,
        )
        assertNotNull(published.analysisId)
        val stored = analysisStore.read(published.analysisId!!)
        assertNotNull(stored)
        assertFalse(stored!!.agentReadable)
        assertNull(stored.ownerTaskId)
        assertNull(stored.ownerWorkspaceId)
    }

    @Test
    fun undrainedSinkIsPreservedAsPartialAndNeverReportedComplete() {
        val store = CaptureArtifactStore(root)
        val sessionId = UUID.randomUUID().toString()
        val artifact = store.begin(
            sessionId = sessionId,
            owner = owner,
            mode = CaptureMode.VPN,
            detailed = true,
            maxBytes = 1_000_000,
            maxPackets = 100,
            maxDurationMillis = 60_000,
        )
        artifact.sink.start()
        artifact.sink.offer(packet(), 0, 20)
        val sink = artifact.sink.closeAndDrain(5_000).copy(drained = false)
        val result = store.finalize(
            artifact = artifact,
            sink = sink,
            state = CaptureState(
                sessionId = sessionId,
                owner = owner,
                mode = CaptureMode.VPN,
                phase = CapturePhase.FINALIZING,
            ),
            startedAtMillis = 1L,
            endedAtMillis = 2L,
            limitations = emptyList(),
        )
        assertTrue(result.partial)
        assertTrue(result.file.name.endsWith("-partial.pcap"))
        val manifest = JSONObject(result.manifestFile.readText())
        assertFalse(manifest.getBoolean("complete"))
        assertFalse(manifest.getJSONObject("sink").getBoolean("drained"))
    }
}
