// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import java.util.UUID

internal data class PhoneControlCapture(
    val observation: PhoneControlObservation,
    val records: Map<String, PhoneControlNodeRecord>,
    val fingerprint: Long,
    val protectedWindow: Boolean,
    val hasSensitiveField: Boolean,
)

/**
 * Builds the only observation that may exist for a Floe foreground: the actual
 * package/window identity plus the live fence/page ticket, with zero nodes.
 * Node children, text, descriptions, hints, view ids, window title, root class
 * name and screenshot pixels are never read for this case, so Floe's own
 * settings/approval content cannot enter the record even transiently.
 *
 * The returned record can authorize only the existing Back/Home navigation or
 * a Launch whose target passes the ordinary non-Floe [PhoneControlPolicy.launchDenial].
 */
internal fun navigationOnlyCapture(
    owner: PhoneControlOwner,
    ticket: PhoneControlFence.Ticket,
    packageName: String?,
    windowId: Int,
    windowType: Int?,
    displayId: Int,
    capturedAtElapsedRealtimeMillis: Long,
    screenshotSupport: PhoneControlScreenshotSupport,
    observationId: String = UUID.randomUUID().toString(),
): PhoneControlCapture {
    val observation = PhoneControlObservation(
        observationId = observationId,
        owner = owner,
        fenceGeneration = ticket.fenceGeneration,
        pageGeneration = ticket.pageGeneration,
        capturedAtElapsedRealtimeMillis = capturedAtElapsedRealtimeMillis,
        expiresAtElapsedRealtimeMillis =
            capturedAtElapsedRealtimeMillis + PhoneControlLimits.OBSERVATION_TTL_MS,
        packageName = PhoneControlText.bound(
            PhoneControlText.clean(packageName),
            PhoneControlLimits.MAX_PACKAGE_CHARS,
        ).text,
        windowId = windowId,
        windowType = windowType,
        windowTitle = null,
        displayId = displayId,
        rootClassName = null,
        sensitiveWindow = true,
        screenshotSupport = screenshotSupport,
        nodes = emptyList(),
        truncated = false,
        maxDepthReached = false,
        navigationOnly = true,
    )
    return PhoneControlCapture(
        observation = observation,
        records = emptyMap(),
        fingerprint = navigationFingerprint(observation.packageName, windowId),
        protectedWindow = true,
        hasSensitiveField = false,
    )
}

/** Metadata-only fingerprint; node content is deliberately never read. */
private fun navigationFingerprint(packageName: String?, windowId: Int): Long {
    var hash = -0x340d631b7bdddcdbL
    for (ch in packageName.orEmpty()) {
        hash = (hash xor ch.code.toLong()) * 0x100000001b3L
    }
    hash = (hash xor 0xfeL) * 0x100000001b3L
    return (hash xor windowId.toLong()) * 0x100000001b3L
}

/**
 * Reads one bounded window snapshot on the service main thread. Node handles
 * are read into primitives and recycled immediately; no live AccessibilityNodeInfo
 * or raw credentials survive this call. Password/sensitive view-id fields are
 * never read.
 */
internal class PhoneControlSnapshotter(private val service: AccessibilityService) {
    private data class ReadStats(
        var nodeLimited: Boolean = false,
        var depthLimited: Boolean = false,
        var hasSensitiveField: Boolean = false,
    )

    @Suppress("DEPRECATION")
    fun capture(
        owner: PhoneControlOwner,
        ticket: PhoneControlFence.Ticket,
        request: PhoneControlObserveRequest,
        keyguardLocked: Boolean,
    ): PhoneControlCapture? {
        val req = request.normalized()
        val root = service.rootInActiveWindow ?: return null
        try {
            val windowId = root.windowId
            val packageName = root.packageName?.toString()
            val navigationOnly = PhoneControlPolicy.isFloePackage(packageName)
            val windows = runCatching { service.windows }.getOrDefault(emptyList())
            val window = windows.firstOrNull { it.id == windowId }
            val windowType = window?.type
            val displayId = if (Build.VERSION.SDK_INT >= 30) {
                window?.displayId ?: Display.DEFAULT_DISPLAY
            } else {
                Display.DEFAULT_DISPLAY
            }
            if (navigationOnly) {
                // Floe's own UI is never traversed: return metadata only,
                // without reading the title, root class or any child node.
                windows.forEach { info -> runCatching { info.recycle() } }
                return navigationOnlyCapture(
                    owner = owner,
                    ticket = ticket,
                    packageName = packageName,
                    windowId = windowId,
                    windowType = windowType,
                    displayId = displayId,
                    capturedAtElapsedRealtimeMillis = SystemClock.elapsedRealtime(),
                    screenshotSupport = PhoneControlPolicy.screenshotSupport(
                        Build.VERSION.SDK_INT,
                    ),
                )
            }
            val className = root.className?.toString()
            val rawWindowTitle = runCatching { window?.title?.toString() }.getOrNull()
            windows.forEach { info -> runCatching { info.recycle() } }

            // Protected windows never need node text at all. Establish that
            // before reading so password/credential/system surfaces are not
            // copied into a local raw list even transiently.
            val preProtected = PhoneControlPolicy.isProtectedWindow(
                packageName = packageName,
                className = className,
                windowType = windowType,
                hasPassword = false,
                keyguardLocked = keyguardLocked,
            )

            val raw = ArrayList<PhoneControlRawNode>(minOf(req.maxNodes, 256))
            val stats = ReadStats()
            readNode(
                node = root,
                path = emptyList(),
                parentPath = null,
                depth = 0,
                redactAllText = preProtected,
                request = req,
                out = raw,
                stats = stats,
            )

            val protectedWindow = PhoneControlPolicy.isProtectedWindow(
                packageName = packageName,
                className = className,
                windowType = windowType,
                hasPassword = stats.hasSensitiveField,
                keyguardLocked = keyguardLocked,
            )
            val redactAllText = protectedWindow
            val shaped = PhoneControlTreeShaper.shape(
                raw = raw,
                request = req,
                redactAllText = redactAllText,
                depthLimited = stats.depthLimited,
                nodeLimited = stats.nodeLimited,
            )
            val capturedAt = SystemClock.elapsedRealtime()
            val observation = PhoneControlObservation(
                observationId = UUID.randomUUID().toString(),
                owner = owner,
                fenceGeneration = ticket.fenceGeneration,
                pageGeneration = ticket.pageGeneration,
                capturedAtElapsedRealtimeMillis = capturedAt,
                expiresAtElapsedRealtimeMillis = capturedAt + PhoneControlLimits.OBSERVATION_TTL_MS,
                packageName = PhoneControlText.bound(
                    PhoneControlText.clean(packageName),
                    PhoneControlLimits.MAX_PACKAGE_CHARS,
                ).text,
                windowId = windowId,
                windowType = windowType,
                windowTitle = if (redactAllText) null else PhoneControlText.bound(
                    PhoneControlText.clean(rawWindowTitle),
                    200,
                ).text,
                displayId = displayId,
                rootClassName = PhoneControlText.bound(PhoneControlText.clean(className), 200).text,
                sensitiveWindow = redactAllText || stats.hasSensitiveField,
                screenshotSupport = PhoneControlPolicy.screenshotSupport(Build.VERSION.SDK_INT),
                nodes = shaped.nodes,
                truncated = shaped.truncated,
                maxDepthReached = shaped.maxDepthReached,
            )
            return PhoneControlCapture(
                observation = observation,
                records = shaped.records,
                fingerprint = shaped.fingerprint,
                protectedWindow = protectedWindow,
                hasSensitiveField = stats.hasSensitiveField,
            )
        } finally {
            @Suppress("DEPRECATION")
            runCatching { root.recycle() }
        }
    }

    @Suppress("DEPRECATION")
    private fun readNode(
        node: AccessibilityNodeInfo,
        path: List<Int>,
        parentPath: List<Int>?,
        depth: Int,
        redactAllText: Boolean,
        request: PhoneControlObserveRequest,
        out: MutableList<PhoneControlRawNode>,
        stats: ReadStats,
    ) {
        if (out.size >= request.maxNodes) {
            stats.nodeLimited = true
            return
        }
        val viewId = runCatching { node.viewIdResourceName }.getOrNull()
        val password = runCatching { node.isPassword }.getOrDefault(false)
        val sensitive = password || PhoneControlText.isSensitiveViewId(viewId)
        if (sensitive) stats.hasSensitiveField = true
        val redact = redactAllText || sensitive

        val bounds = Rect()
        runCatching { node.getBoundsInScreen(bounds) }
        out += PhoneControlRawNode(
            path = path,
            parentPath = parentPath,
            depth = depth,
            className = node.className?.toString().orEmpty(),
            packageName = node.packageName?.toString(),
            viewId = viewId,
            text = if (redact) null else node.text?.toString(),
            contentDescription = if (redact) null else node.contentDescription?.toString(),
            hintText = if (redact) null else runCatching { node.hintText?.toString() }.getOrNull(),
            bounds = PhoneControlBounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
            visible = runCatching { node.isVisibleToUser }.getOrDefault(false),
            clickable = runCatching { node.isClickable }.getOrDefault(false),
            editable = runCatching { node.isEditable }.getOrDefault(false),
            scrollable = runCatching { node.isScrollable }.getOrDefault(false),
            enabled = runCatching { node.isEnabled }.getOrDefault(false),
            selected = runCatching { node.isSelected }.getOrDefault(false),
            checkable = runCatching { node.isCheckable }.getOrDefault(false),
            checked = runCatching { node.isChecked }.getOrDefault(false),
            password = password,
        )

        if (depth >= request.maxDepth) {
            if (runCatching { node.childCount }.getOrDefault(0) > 0) stats.depthLimited = true
            return
        }
        val childCount = runCatching { node.childCount }.getOrDefault(0)
        for (index in 0 until childCount) {
            if (out.size >= request.maxNodes) {
                stats.nodeLimited = true
                return
            }
            val child = runCatching { node.getChild(index) }.getOrNull() ?: continue
            try {
                readNode(
                    node = child,
                    path = path + index,
                    parentPath = path,
                    depth = depth + 1,
                    redactAllText = redactAllText,
                    request = request,
                    out = out,
                    stats = stats,
                )
            } finally {
                @Suppress("DEPRECATION")
                runCatching { child.recycle() }
            }
        }
    }
}
