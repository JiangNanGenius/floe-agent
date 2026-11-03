// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.workbench

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Authored G09-R2 media-enhancement contract checks. NOT RUN in this source
 * lane: they pin the frozen Kotlin mirror of the native enhancement contract
 * (operation vocabulary, limits, state machine, retryable codes) without any
 * native or provider dependency.
 */
class WorkbenchEnhancementContractTest {

    @Test
    fun interpolationCarriesExactTargetFPS() {
        val op = EnhancementOperation.Interpolation(targetFPS = 120.0)
        assertEquals(EnhancementMethod.INTERPOLATION, op.method)
        assertEquals(120.0, (op as EnhancementOperation.Interpolation).targetFPS, 0.0)
    }

    @Test
    fun superResolutionCarriesScaleAndBitDepth() {
        val op = EnhancementOperation.SuperResolution(scaleFactor = 3, bitDepth = 10)
        assertEquals(EnhancementMethod.SUPER_RESOLUTION, op.method)
        assertEquals(3, op.scaleFactor)
        assertEquals(10, op.bitDepth)
    }

    @Test
    fun requestDefaultsToNoOverwrite() {
        val request = EnhancementRequest(
            inputRelativePath = "Assets/clip.mp4",
            operation = EnhancementOperation.Interpolation(60.0),
            outputFileName = "out.mp4",
        )
        assertFalse(request.overwrite)
    }

    @Test
    fun limitsMatchNativeContract() {
        val limits = EnhancementLimits()
        assertEquals(4096, limits.maximumSourceDimension)
        assertEquals(8192, limits.maximumOutputDimension)
        assertEquals(3600, limits.maximumDurationSeconds)
        assertEquals(200_000, limits.maximumFrames)
        assertEquals(240.0, limits.maximumTargetFPS, 0.0)
        assertEquals(listOf(2, 3, 4), limits.scaleFactors)
    }

    @Test
    fun terminalStatesAreCompleteFailedCancelledUnknown() {
        assertTrue(EnhancementJobState.COMPLETED.isTerminal)
        assertTrue(EnhancementJobState.FAILED.isTerminal)
        assertTrue(EnhancementJobState.CANCELLED.isTerminal)
        assertTrue(EnhancementJobState.OUTCOME_UNKNOWN.isTerminal)
        assertFalse(EnhancementJobState.QUEUED.isTerminal)
        assertFalse(EnhancementJobState.RUNNING.isTerminal)
        assertFalse(EnhancementJobState.VALIDATING.isTerminal)
    }

    @Test
    fun progressFractionIsBounded() {
        val progress = EnhancementProgress(
            phase = EnhancementPhase.PROCESSING,
            completedUnits = 3,
            totalUnits = 4,
        )
        assertEquals(0.75, progress.fraction, 0.0001)
        val zero = EnhancementProgress(
            phase = EnhancementPhase.PREFLIGHT,
            completedUnits = 0,
            totalUnits = 0,
        )
        assertEquals(0.0, zero.fraction, 0.0)
        val over = EnhancementProgress(
            phase = EnhancementPhase.PROCESSING,
            completedUnits = 9,
            totalUnits = 4,
        )
        assertEquals(1.0, over.fraction, 0.0)
    }

    @Test
    fun retryableCodesCoverRefusalsAndUnknown() {
        assertTrue(EnhancementErrorCodes.RETRYABLE.contains(EnhancementErrorCodes.BACKEND_UNAVAILABLE))
        assertTrue(EnhancementErrorCodes.RETRYABLE.contains(EnhancementErrorCodes.OUTCOME_UNKNOWN))
        assertTrue(EnhancementErrorCodes.RETRYABLE.contains(EnhancementErrorCodes.TASK_CONTEXT_REQUIRED))
        assertTrue(EnhancementErrorCodes.RETRYABLE.contains(EnhancementErrorCodes.UNSUPPORTED_COMBINATION))
        assertTrue(EnhancementErrorCodes.RETRYABLE.contains(EnhancementErrorCodes.OUTPUT_EXISTS))
        assertFalse(EnhancementErrorCodes.RETRYABLE.contains(EnhancementErrorCodes.CANCELLED))
    }

    @Test
    fun receiptCarriesMeasuredIdentity() {
        val receipt = EnhancementReceipt(
            outputRelativePath = "Enhancements/out.mp4",
            engine = "ffmpeg-minterpolate",
            method = EnhancementMethod.INTERPOLATION,
            inputKind = "video",
            sourceWidth = 1920,
            sourceHeight = 1080,
            sourceFPS = 30.0,
            sourceDurationSeconds = 10.0,
            sourceFrameCount = 300,
            outputWidth = 1920,
            outputHeight = 1080,
            outputFPS = 120.0,
            outputDurationSeconds = 10.0,
            outputFrameCount = 1200,
            outputBytes = 8_000_000,
            outputSHA256 = "ab".repeat(32),
            remoteJobID = null,
            warnings = emptyList(),
        )
        assertEquals("Enhancements/out.mp4", receipt.outputRelativePath)
        assertEquals("ffmpeg-minterpolate", receipt.engine)
        assertEquals(1200, receipt.outputFrameCount)
        assertNull(receipt.remoteJobID)
    }

    @Test
    fun capabilityHonestyFields() {
        val capability = EnhancementCapability(
            interpolationReady = true,
            interpolationEngine = "ffmpeg-minterpolate",
            interpolationUnavailableReason = null,
            superResolutionReady = false,
            superResolutionBackendName = null,
            superResolutionUnavailableReason = "backendNotConfigured",
        )
        assertTrue(capability.interpolationReady)
        assertFalse(capability.superResolutionReady)
        assertEquals("backendNotConfigured", capability.superResolutionUnavailableReason)
    }

    @Test
    fun receiptCarriesImportIdentityDefaults() {
        val receipt = EnhancementReceipt(
            outputRelativePath = "Enhancements/out.mp4",
            engine = "fal",
            method = EnhancementMethod.SUPER_RESOLUTION,
            inputKind = "video",
            sourceWidth = 1920,
            sourceHeight = 1080,
            sourceFPS = 30.0,
            sourceDurationSeconds = 10.0,
            sourceFrameCount = 300,
            outputWidth = 3840,
            outputHeight = 2160,
            outputFPS = 30.0,
            outputDurationSeconds = 10.0,
            outputFrameCount = 300,
            outputBytes = 1,
            outputSHA256 = "cd".repeat(32),
            remoteJobID = "req-1",
            warnings = emptyList(),
        )
        // Import identity is additive: absent until the original importAsset
        // ownership lands; failure code stays separate from measured fields.
        assertNull(receipt.importedAssetID)
        assertNull(receipt.importRevision)
        assertNull(receipt.importErrorCode)
        val imported = receipt.copy(importedAssetID = "asset-1", importRevision = 7)
        assertEquals("asset-1", imported.importedAssetID)
        assertEquals(7L, imported.importRevision)
    }

    @Test
    fun configurationDefaultsMirrorNativeAccount() {
        // Pinned against G09R2EnhancerBackendConfiguration.defaultCredentialAccount
        // so the App-side credential write and the native read can never
        // drift apart silently.
        assertEquals(
            "media.enhancement.superResolution",
            EnhancementBackendConfiguration.DEFAULT_CREDENTIAL_ACCOUNT,
        )
        val empty = EnhancementBackendConfiguration(
            configured = false,
            displayName = null,
            endpointID = "fal-ai/bytedance-upscaler/upscale/video",
            credentialConfigured = false,
            legacyProviderProfileReferenced = false,
        )
        assertFalse(empty.configured)
        val legacy = empty.copy(
            configured = true,
            credentialConfigured = false,
            legacyProviderProfileReferenced = true,
        )
        assertTrue(legacy.legacyProviderProfileReferenced)
    }

    @Test
    fun configurationRefusalCodesAreClosed() {
        assertEquals("enhancerInvalidEndpoint", EnhancementErrorCodes.ENHANCER_INVALID_ENDPOINT)
        assertEquals("enhancerInvalidAccount", EnhancementErrorCodes.ENHANCER_INVALID_ACCOUNT)
        assertEquals("enhancerStoreUnavailable", EnhancementErrorCodes.ENHANCER_STORE_UNAVAILABLE)
        assertEquals("enhancerCredentialMissing", EnhancementErrorCodes.ENHANCER_CREDENTIAL_MISSING)
    }
}
