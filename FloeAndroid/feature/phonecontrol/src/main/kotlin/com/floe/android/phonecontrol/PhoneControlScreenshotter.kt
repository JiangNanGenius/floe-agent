// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Bounded screenshot bridge. API 30 adds display capture; API 34 adds the
 * window-scoped overload. A window-scoped request on API 30-33 is reported as
 * unsupported rather than silently falling back to a broader display capture.
 *
 * The returned bytes are an in-memory JPEG only; nothing is written to disk,
 * logged, or retained here. Compression/downscaling happens on one owned
 * worker thread, never on the service main thread.
 */
internal class PhoneControlScreenshotter(
    private val service: AccessibilityService,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "floe-phonecontrol-screenshot").apply { isDaemon = true }
    }
    private val workerExecutor = Executor { command ->
        if (!closed.get()) {
            runCatching { worker.execute(command) }
        }
    }

    fun capture(
        displayId: Int,
        windowId: Int?,
        request: PhoneControlScreenshotRequest,
        onResult: (PhoneControlResult<PhoneControlScreenshot>) -> Unit,
    ) {
        if (closed.get()) {
            onResult(PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED))
            return
        }
        if (Build.VERSION.SDK_INT < 30) {
            onResult(PhoneControlResult.Unavailable(PhoneControlUnavailable.SCREENSHOT_UNSUPPORTED))
            return
        }
        if (windowId != null && Build.VERSION.SDK_INT < 34) {
            onResult(PhoneControlResult.Unavailable(
                PhoneControlUnavailable.WINDOW_SCREENSHOT_UNSUPPORTED,
            ))
            return
        }
        val normalized = request.normalized()
        val callback = object : AccessibilityService.TakeScreenshotCallback {
            override fun onSuccess(screenshot: AccessibilityService.ScreenshotResult) {
                val result = runCatching {
                    process(screenshot, normalized, windowId)
                }.getOrElse {
                    PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)
                }
                postResult(result, onResult)
            }

            override fun onFailure(errorCode: Int) {
                postResult(failure(errorCode), onResult)
            }
        }
        val dispatched = runCatching {
            if (windowId != null) {
                service.takeScreenshotOfWindow(windowId, workerExecutor, callback)
            } else {
                service.takeScreenshot(displayId, workerExecutor, callback)
            }
        }
        if (dispatched.isFailure) {
            onResult(PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED))
        }
    }

    fun close() {
        if (closed.compareAndSet(false, true)) {
            runCatching { worker.shutdownNow() }
        }
    }

    private fun process(
        result: AccessibilityService.ScreenshotResult,
        request: PhoneControlScreenshotRequest,
        windowId: Int?,
    ): PhoneControlResult<PhoneControlScreenshot> {
        if (Build.VERSION.SDK_INT < 30) {
            return PhoneControlResult.Unavailable(PhoneControlUnavailable.SCREENSHOT_UNSUPPORTED)
        }
        val buffer = result.hardwareBuffer
        try {
            val wrapped = Bitmap.wrapHardwareBuffer(buffer, result.colorSpace)
                ?: return PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)
            val software = try {
                wrapped.copy(Bitmap.Config.ARGB_8888, false)
            } finally {
                wrapped.recycle()
            } ?: return PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)

            var scaled = software
            try {
                val maxDimension = max(scaled.width, scaled.height)
                if (maxDimension > request.maxDimension) {
                    val ratio = request.maxDimension.toFloat() / maxDimension.toFloat()
                    val width = max(1, (scaled.width * ratio).roundToInt())
                    val height = max(1, (scaled.height * ratio).roundToInt())
                    val resized = Bitmap.createScaledBitmap(scaled, width, height, true)
                    if (resized !== scaled) {
                        scaled.recycle()
                        scaled = resized
                    }
                }

                var quality = request.quality
                var attempt = 0
                while (true) {
                    val output = ByteArrayOutputStream()
                    if (!scaled.compress(Bitmap.CompressFormat.JPEG, quality, output)) {
                        return PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)
                    }
                    val bytes = output.toByteArray()
                    if (bytes.isEmpty()) {
                        return PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)
                    }
                    if (bytes.size <= request.maxBytes) {
                        return PhoneControlResult.Ok(
                            PhoneControlScreenshot(
                                bytes = bytes,
                                mimeType = "image/jpeg",
                                width = scaled.width,
                                height = scaled.height,
                                capturedAtElapsedRealtimeMillis = SystemClock.elapsedRealtime(),
                                windowId = windowId,
                            ),
                        )
                    }
                    if (quality > PhoneControlLimits.MIN_SCREENSHOT_QUALITY) {
                        quality = (quality - 10)
                            .coerceAtLeast(PhoneControlLimits.MIN_SCREENSHOT_QUALITY)
                        continue
                    }
                    if (attempt >= 3) break
                    val nextWidth = max(1, (scaled.width * 3) / 4)
                    val nextHeight = max(1, (scaled.height * 3) / 4)
                    if (nextWidth >= scaled.width && nextHeight >= scaled.height) break
                    val next = Bitmap.createScaledBitmap(scaled, nextWidth, nextHeight, true)
                    if (next !== scaled) scaled.recycle()
                    scaled = next
                    quality = request.quality
                    attempt += 1
                }
                return PhoneControlResult.Failed(PhoneControlFailure.IMAGE_TOO_LARGE)
            } finally {
                scaled.recycle()
            }
        } catch (error: Exception) {
            return PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)
        } finally {
            runCatching { buffer.close() }
        }
    }

    private fun failure(errorCode: Int): PhoneControlResult<PhoneControlScreenshot> =
        when (errorCode) {
            AccessibilityService.ERROR_TAKE_SCREENSHOT_SECURE_WINDOW ->
                PhoneControlResult.Failed(PhoneControlFailure.CAPTURE_SECURE_WINDOW)
            AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT ->
                PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_THROTTLED)
            AccessibilityService.ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS ->
                PhoneControlResult.Failed(
                    PhoneControlFailure.SCREENSHOT_FAILED,
                    "accessibility screenshot access is not available",
                )
            AccessibilityService.ERROR_TAKE_SCREENSHOT_INVALID_WINDOW ->
                PhoneControlResult.Failed(
                    PhoneControlFailure.SCREENSHOT_FAILED,
                    "window is no longer capturable",
                )
            else ->
                PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)
        }

    private fun postResult(
        result: PhoneControlResult<PhoneControlScreenshot>,
        onResult: (PhoneControlResult<PhoneControlScreenshot>) -> Unit,
    ) {
        mainHandler.post { onResult(result) }
    }
}
