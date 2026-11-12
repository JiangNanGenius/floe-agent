// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.externaledit

import java.util.Locale
import java.util.UUID

/**
 * Read-only native handoff policy: task-owned bytes -> App-owned FileProvider
 * URI -> one explicitly resolved installed handler.
 *
 * This file deliberately carries no Android types so the actual target
 * filtering, closed MIME agreement, duplicate-launch rules and the read-only
 * grant shape are JVM-testable. The controller only performs the real
 * PackageManager query and Activity launch through these decisions.
 *
 * Invariants encoded here (and nowhere weakened by the controller):
 *  - only a CLOSED extension -> MIME map is accepted; a model-supplied MIME
 *    or an unknown extension is never trusted;
 *  - a target must be an installed ACTION_VIEW handler for that exact MIME
 *    AND belong to the user's existing Settings > Device target-app ceiling;
 *  - the Android resolver/system packages are refused even if a stale
 *    settings value named them (no broad `android` authorization, no chooser);
 *  - the launch is READ-ONLY: read permission only, never write permission,
 *    and the App never claims an edit or import was completed.
 */
internal data class ArtifactHandoffMime(
    val primary: String,
    val alternatives: List<String> = emptyList(),
) {
    val all: List<String> get() = listOf(primary) + alternatives
    fun accepts(value: String): Boolean = value in all
}

/** One installed resolver row, already reduced to inert metadata. */
internal data class ArtifactHandoffHandler(
    val packageName: String,
    val className: String,
    val label: String,
    val priority: Int,
    val mimeType: String,
) {
    val componentName: String get() = "$packageName/$className"
}

internal sealed class ArtifactHandoffTargetChoice {
    data class Selected(val handler: ArtifactHandoffHandler) : ArtifactHandoffTargetChoice()
    data class Ambiguous(val handlers: List<ArtifactHandoffHandler>) : ArtifactHandoffTargetChoice()
    object None : ArtifactHandoffTargetChoice()
    data class Refused(val code: String) : ArtifactHandoffTargetChoice()
}

/** Classification of the one OS start boundary. */
internal enum class ArtifactHandoffStartDisposition {
    /** The platform start call returned; the explicit start is accepted. */
    ACCEPTED,

    /** Closed known no-dispatch exceptions (ActivityNotFoundException /
     * SecurityException) or a trusted preflight refusal. */
    NOT_DISPATCHED,

    /** The OS call was attempted (or an unobserved exception occurred) with
     * no accepted receipt; this must never be replayed. */
    UNKNOWN,
}

/** The exact route a verified handoff may use for its one OS launch. */
internal enum class ArtifactHandoffLaunchRoute {
    /** This task's conversation is visibly foreground: direct Activity start. */
    FOREGROUND,

    /** Floe is visible on a different conversation: a real user foreground
     * step, never a silent device-automation takeover. */
    FOREGROUND_REQUIRED,

    /** Floe is backgrounded and the Full Phone route is present: typed
     * read-only VIEW under the existing armed-owner/session fence. */
    BACKGROUND,

    /** Floe is backgrounded and no Phone route is wired: fail closed. */
    UNAVAILABLE,
}

/** The only allowed outcomes of a repeated open decision. */
internal enum class ArtifactHandoffLaunchDisposition {
    /** No OS launch has been accepted; preflight failures are retryable. */
    READY,

    /** This exact record's Activity start was already accepted. */
    ALREADY_LAUNCHED,

    /** A launch may have reached the OS; never replay it. */
    OUTCOME_UNKNOWN,

    /** Finished/cancelled records are not opened again. */
    TERMINAL,
}

/** The exact grant shape passed to the platform. A future edit lane must be
 * a distinct tool/record; it may never silently add write here. */
internal data class ArtifactHandoffLaunch(
    val action: String,
    val packageName: String,
    val className: String,
    val mimeType: String,
    val readPermission: Boolean,
    val writePermission: Boolean,
    val clipLabel: String,
)

internal object ArtifactHandoffPolicy {
    const val VIEW_ACTION = "android.intent.action.VIEW"
    const val FLAG_GRANT_READ_URI_PERMISSION = 0x00000001
    const val FLAG_GRANT_WRITE_URI_PERMISSION = 0x00000002
    const val MAX_BYTES = 256L * 1024 * 1024
    const val MAX_ACTIVE = 16
    const val MAX_TARGETS = 8
    const val MAX_DISPLAY_NAME = 160

    private fun mime(primary: String, vararg alternatives: String) =
        ArtifactHandoffMime(primary, alternatives.toList())

    /** Closed formats a native viewer/importer may receive. Extensions are
     * lowercased without locale surprises; no wildcard MIME is emitted. */
    private val MIME_BY_EXTENSION: Map<String, ArtifactHandoffMime> = mapOf(
        // Video (the demo's 12s 1080p MP4 is the primary case).
        "mp4" to mime("video/mp4"),
        "m4v" to mime("video/mp4"),
        "webm" to mime("video/webm"),
        "3gp" to mime("video/3gpp"),
        "mov" to mime("video/quicktime"),
        // Image.
        "jpg" to mime("image/jpeg"),
        "jpeg" to mime("image/jpeg"),
        "png" to mime("image/png"),
        "webp" to mime("image/webp"),
        "gif" to mime("image/gif"),
        // Documents / text.
        "pdf" to mime("application/pdf"),
        "txt" to mime("text/plain"),
        "md" to mime("text/plain"),
        "csv" to mime("text/plain"),
        "json" to mime("text/plain"),
        "log" to mime("text/plain"),
        // Audio.
        "mp3" to mime("audio/mpeg"),
        "m4a" to mime("audio/mp4"),
        "wav" to mime("audio/wav"),
        "ogg" to mime("audio/ogg"),
        "oga" to mime("audio/ogg"),
        // Calendar import. Both handler families are real on shipped ROMs;
        // the matched row's own MIME is what is launched.
        "ics" to mime("text/calendar", "text/x-vcalendar"),
    )

    val supportedExtensions: Set<String> get() = MIME_BY_EXTENSION.keys
    val outputFormats: Set<String> get() = MIME_BY_EXTENSION.keys

    fun mimeFor(displayName: String): ArtifactHandoffMime? =
        MIME_BY_EXTENSION[extensionOf(displayName)]

    /** Sealed run-output MIME must AGREE with the sealed name; an
     * `application/octet-stream` claim over a video name is not viewable. */
    fun mimeMatchesExtension(displayName: String, sealedMime: String): Boolean =
        mimeFor(displayName)?.accepts(sealedMime) == true

    fun extensionOf(displayName: String): String =
        displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)

    /** One inert single-component file name derived from the path, not from
     * model text. Empty/dot/control names are refused. */
    fun displayNameFor(path: String): String? {
        val name = path.substringAfterLast('/')
        if (name.isEmpty() || name.length > MAX_DISPLAY_NAME || name.startsWith('.') ||
            name.any { it == '\\' || it.code < 32 }) return null
        return name
    }

    fun validPath(path: String): Boolean = ExternalEditPolicy.validPath(path)

    fun validOutputID(value: String): Boolean = value.length == 64 &&
        value.all { it in '0'..'9' || it in 'a'..'f' }

    fun validSessionID(value: String): Boolean = runCatching {
        UUID.fromString(value).toString().equals(value, ignoreCase = true)
    }.getOrDefault(false)

    /** Structural request checks shared by the Swift tool schema and the
     * Kotlin host. Kept here so a test proves the exact same rules. */
    fun validSource(source: String, path: String?, outputID: String?): Boolean = when (source) {
        "workspace" -> path != null && validPath(path) && outputID == null
        "output" -> path == null && outputID != null && validOutputID(outputID)
        else -> false
    }

    fun validTargetFields(targetPackage: String?, targetComponent: String?): Boolean {
        if (targetComponent != null) {
            val separator = targetComponent.indexOf('/')
            if (separator <= 0 || separator == targetComponent.lastIndex) return false
            val componentPackage = targetComponent.substring(0, separator)
            if (targetPackage != null && targetPackage != componentPackage) return false
        }
        if (targetPackage != null &&
            (targetPackage.isEmpty() || targetPackage.length > 255 ||
                targetPackage.any { it.code < 33 || it.code > 126 || it == '/' })) return false
        return true
    }

    /** System resolver / internal packages are never a permitted target,
     * even when a stale settings value names them. This is the exact
     * FS10 boundary: do not authorize `android` or automate its chooser. */
    fun forbiddenPackage(packageName: String, ownPackage: String): Boolean =
        packageName.isEmpty() ||
            packageName == ownPackage ||
            packageName == "android" ||
            packageName.startsWith("com.android.internal.") ||
            packageName == "com.android.intentresolver"

    /** Filter to the user's current target-app ceiling, dedupe by concrete
     * component and drop wildcard/empty metadata. */
    fun permittedHandlers(
        handlers: List<ArtifactHandoffHandler>,
        allowedPackages: Set<String>,
        ownPackage: String,
    ): List<ArtifactHandoffHandler> = handlers
        .asSequence()
        .filter { it.packageName in allowedPackages }
        .filterNot { forbiddenPackage(it.packageName, ownPackage) }
        .filter { it.className.isNotEmpty() && it.mimeType.isNotEmpty() }
        .sortedWith(compareByDescending<ArtifactHandoffHandler> { it.priority }
            .thenBy { it.label.lowercase(Locale.ROOT) }
            .thenBy { it.packageName }
            .thenBy { it.className })
        .distinctBy { it.componentName }
        .take(MAX_TARGETS)
        .toList()

    /** Explicit exact component > explicit package > single installed row.
     * Multiple permitted rows are returned as candidates so the model can
     * choose an installed handler; the App never opens an operator chooser. */
    fun selectTarget(
        candidates: List<ArtifactHandoffHandler>,
        targetPackage: String?,
        targetComponent: String?,
    ): ArtifactHandoffTargetChoice {
        val filtered = candidates.distinctBy { it.componentName }
        if (targetComponent != null) {
            val exact = filtered.firstOrNull { it.componentName == targetComponent }
                ?: return ArtifactHandoffTargetChoice.Refused("targetNotPermitted")
            if (targetPackage != null && exact.packageName != targetPackage) {
                return ArtifactHandoffTargetChoice.Refused("targetNotPermitted")
            }
            return ArtifactHandoffTargetChoice.Selected(exact)
        }
        if (targetPackage != null) {
            val matching = filtered.filter { it.packageName == targetPackage }
            return when (matching.size) {
                1 -> ArtifactHandoffTargetChoice.Selected(matching.single())
                0 -> ArtifactHandoffTargetChoice.Refused("targetNotPermitted")
                else -> ArtifactHandoffTargetChoice.Ambiguous(matching)
            }
        }
        return when (filtered.size) {
            1 -> ArtifactHandoffTargetChoice.Selected(filtered.single())
            0 -> ArtifactHandoffTargetChoice.None
            else -> ArtifactHandoffTargetChoice.Ambiguous(filtered)
        }
    }

    fun launchFor(handler: ArtifactHandoffHandler, displayName: String): ArtifactHandoffLaunch =
        ArtifactHandoffLaunch(
            action = VIEW_ACTION,
            packageName = handler.packageName,
            className = handler.className,
            mimeType = handler.mimeType,
            readPermission = true,
            writePermission = false,
            clipLabel = displayName,
        )

    /** Intent flags for the one read-only grant. A launch spec with a write
     * bit is refused rather than silently downgraded. */
    fun grantFlags(launch: ArtifactHandoffLaunch): Int {
        require(!launch.writePermission && launch.readPermission)
        return FLAG_GRANT_READ_URI_PERMISSION
    }

    /**
     * Classify one start boundary without Android types. Only a returned
     * start is an acceptance; only the closed known no-dispatch cases are
     * retryable. Any other exception after an OS attempt is UNKNOWN.
     */
    fun startDisposition(
        startReturned: Boolean,
        knownNonDispatch: Boolean,
    ): ArtifactHandoffStartDisposition = when {
        startReturned -> ArtifactHandoffStartDisposition.ACCEPTED
        knownNonDispatch -> ArtifactHandoffStartDisposition.NOT_DISPATCHED
        else -> ArtifactHandoffStartDisposition.UNKNOWN
    }

    /**
     * What a repeated open may do with this record. This keeps the two
     * materially different failures apart:
     *  - a definite pre-dispatch refusal is retryable after the Agent really
     *    prepares the required target/foreground/Phone scope;
     *  - an unconfirmed OS launch is never replayed under any call.
     */
    fun launchDisposition(record: ArtifactHandoffRecord): ArtifactHandoffLaunchDisposition =
        when {
            record.launchAttempt == ArtifactHandoffLaunchAttempt.ACCEPTED ->
                ArtifactHandoffLaunchDisposition.ALREADY_LAUNCHED
            record.phase == ArtifactHandoffPhase.FINISHED ||
                record.phase == ArtifactHandoffPhase.CANCELLED ->
                ArtifactHandoffLaunchDisposition.TERMINAL
            record.launchAttempt == ArtifactHandoffLaunchAttempt.UNKNOWN ->
                ArtifactHandoffLaunchDisposition.OUTCOME_UNKNOWN
            else -> ArtifactHandoffLaunchDisposition.READY
        }

    /** Stable, bounded wire token for status/diagnostics. */
    fun launchStateName(record: ArtifactHandoffRecord): String = when (record.launchAttempt) {
        ArtifactHandoffLaunchAttempt.NONE -> "notAttempted"
        ArtifactHandoffLaunchAttempt.REJECTED -> "notDispatched"
        ArtifactHandoffLaunchAttempt.UNKNOWN -> "unknown"
        ArtifactHandoffLaunchAttempt.ACCEPTED -> "accepted"
    }

    /**
     * Foreground wins for ordinary UI use; a visibly different Floe task stays
     * a foreground requirement; only a genuinely backgrounded App may use the
     * optional Phone route, and its absence fails closed.
     */
    fun launchRoute(
        taskVisibleAndSelected: Boolean,
        floeVisible: Boolean,
        backgroundAvailable: Boolean,
    ): ArtifactHandoffLaunchRoute = when {
        taskVisibleAndSelected -> ArtifactHandoffLaunchRoute.FOREGROUND
        floeVisible -> ArtifactHandoffLaunchRoute.FOREGROUND_REQUIRED
        backgroundAvailable -> ArtifactHandoffLaunchRoute.BACKGROUND
        else -> ArtifactHandoffLaunchRoute.UNAVAILABLE
    }

    fun canIssueLaunch(record: ArtifactHandoffRecord): Boolean =
        launchDisposition(record) == ArtifactHandoffLaunchDisposition.READY

    /**
     * A NEW call for the same owner/source must not restage/replay around an
     * active record whose OS launch outcome was never recorded. Only an
     * explicit finish/cancel clears it.
     */
    fun blocksNewLaunch(record: ArtifactHandoffRecord): Boolean =
        record.launchAttempt == ArtifactHandoffLaunchAttempt.UNKNOWN && canResume(record)

    fun canResume(record: ArtifactHandoffRecord): Boolean =
        record.phase in setOf(ArtifactHandoffPhase.STAGED, ArtifactHandoffPhase.LAUNCHED,
            ArtifactHandoffPhase.PAUSED)

    fun sourceMatches(record: ArtifactHandoffRecord, source: String, path: String?,
                      outputID: String?): Boolean =
        record.source == source &&
            (source != "workspace" || record.logicalPath == path) &&
            (source != "output" || (record.outputID == outputID && record.runID != null))
}
