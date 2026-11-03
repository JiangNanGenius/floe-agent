// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.revisionreview

import com.floe.android.core.officeengine.OfficeDocumentFormat

/**
 * Real pinned-engine tracked-change commands and their observed states.
 *
 * Every command below is part of the staged Collabora 26.04.4.2 mobile
 * payload's own Writer review menu (`bundle.js` `ChangesMenu`, `changesmenu`
 * action list and `addWriterCommands()`), not a guessed UNO name:
 *
 *  - `.uno:TrackChanges` / `.uno:ShowTrackedChanges`
 *  - `.uno:AcceptTrackedChange` / `.uno:RejectTrackedChange`
 *  - `.uno:AcceptTrackedChangeToNext` / `.uno:RejectTrackedChangeToNext`
 *  - `.uno:AcceptAllTrackedChanges` / `.uno:RejectAllTrackedChanges`
 *  - `.uno:PreviousTrackedChange` / `.uno:NextTrackedChange`
 *
 * The module never invents a command, never marks dispatch as success, and
 * never reports a state it did not receive from the engine. The pinned mobile
 * review surface is Writer-only (the payload binds these actions in
 * `addWriterCommands`), so other formats report an honest support limit
 * instead of exposing dead buttons.
 */
enum class OfficeRevisionAction(
    val command: String,
    /** True when the command can change document/redline content. */
    val mutatesDocument: Boolean,
    /** True when the engine is expected to publish a matching `statechanged:`. */
    val expectsStateChange: Boolean,
) {
    TOGGLE_RECORDING(".uno:TrackChanges", mutatesDocument = false, expectsStateChange = true),
    SHOW_CHANGES(".uno:ShowTrackedChanges", mutatesDocument = false, expectsStateChange = true),
    ACCEPT_CURRENT(".uno:AcceptTrackedChange", mutatesDocument = true, expectsStateChange = true),
    ACCEPT_NEXT(".uno:AcceptTrackedChangeToNext", mutatesDocument = true, expectsStateChange = true),
    REJECT_CURRENT(".uno:RejectTrackedChange", mutatesDocument = true, expectsStateChange = true),
    REJECT_NEXT(".uno:RejectTrackedChangeToNext", mutatesDocument = true, expectsStateChange = true),
    ACCEPT_ALL(".uno:AcceptAllTrackedChanges", mutatesDocument = true, expectsStateChange = true),
    REJECT_ALL(".uno:RejectAllTrackedChanges", mutatesDocument = true, expectsStateChange = true),
    PREVIOUS(".uno:PreviousTrackedChange", mutatesDocument = false, expectsStateChange = false),
    NEXT(".uno:NextTrackedChange", mutatesDocument = false, expectsStateChange = false),
    ;

    /** Exact wire frame sent over the proven `postMobileMessageNative` lane. */
    val wireFrame: String get() = "uno $command"
}

/** Why review is or is not offered for this mount (displayed truthfully). */
enum class OfficeRevisionSupport {
    SUPPORTED,

    /** The pinned mobile review actions are bound for Writer only. */
    WRITER_ONLY,

    /** The engine/mount has not established editable review authority. */
    EDIT_MODE_REQUIRED,

    /** The server side (`filemode: manageRedlines`) refused redline management. */
    REVIEW_NOT_AUTHORIZED,

    /** No live editable mount for this exact token/generation. */
    NO_LIVE_EDIT_SESSION,

    /** A precision mutation holds the single native session lease. */
    NATIVE_LEASE_BUSY,

    /** Another review command is still waiting for its engine acknowledgement. */
    ACTION_PENDING,
}

enum class OfficeRevisionDispatch {
    ACCEPTED,
    NO_LIVE_EDIT_SESSION,
    WRITER_ONLY,
    EDIT_MODE_REQUIRED,
    REVIEW_NOT_AUTHORIZED,
    NATIVE_LEASE_BUSY,
    ACTION_PENDING,
    TRANSPORT_FAILED,
}

/** One immutable projection of the engine's observed review state. */
data class OfficeRevisionState(
    val sessionToken: String,
    val generation: Long,
    val support: OfficeRevisionSupport,
    val manageRedlines: Boolean,
    val pageEditMode: Boolean,
    val recording: Boolean?,
    val showingChanges: Boolean?,
    val acceptCurrentAvailable: Boolean?,
    val rejectCurrentAvailable: Boolean?,
    val acceptAllAvailable: Boolean?,
    val rejectAllAvailable: Boolean?,
    val previousAvailable: Boolean?,
    val nextAvailable: Boolean?,
    val pendingAction: OfficeRevisionAction?,
    val pendingTimedOut: Boolean,
    val lastAcknowledged: OfficeRevisionAction?,
    val lastFailure: String?,
    val mutationEpoch: Long,
    val observedAtElapsedMs: Long,
) {
    val supported: Boolean get() = support == OfficeRevisionSupport.SUPPORTED
    val actionAvailable: Boolean
        get() = supported && pendingAction == null && pageEditMode
}

object OfficeRevisionContract {
    /** Exact `statechanged:` command names the review UI consumes. */
    val observedCommands: Set<String> = setOf(
        ".uno:TrackChanges",
        ".uno:ShowTrackedChanges",
        ".uno:AcceptTrackedChange",
        ".uno:RejectTrackedChange",
        ".uno:AcceptTrackedChanges",
        ".uno:RejectTrackedChanges",
        ".uno:AcceptTrackedChangeToNext",
        ".uno:RejectTrackedChangeToNext",
        ".uno:AcceptAllTrackedChanges",
        ".uno:RejectAllTrackedChanges",
        ".uno:PreviousTrackedChange",
        ".uno:NextTrackedChange",
    )

    /** Writer-only in the staged mobile payload (see class header). */
    fun supports(format: OfficeDocumentFormat): Boolean = format == OfficeDocumentFormat.DOCX

    /**
     * Tri-state reader for the raw `statechanged:` value. `null` means the
     * engine did not state the fact; a UI must not turn that into `false`.
     */
    fun enabled(rawState: String?): Boolean? = when (rawState) {
        null -> null
        "true", "enabled", "checked" -> true
        "false", "disabled", "unchecked" -> false
        else -> null
    }

    /**
     * Extracts the command token from a page-issued `uno` frame. Only an
     * exact `uno .uno:<name>` (optionally with query/args) is returned.
     * Used solely to observe accept/reject activity; it never forwards or
     * rewrites a page command.
     */
    fun pageUnoCommand(message: String): String? {
        val parts = message.trim().split(' ', limit = 3)
        if (parts.size < 2 || parts[0] != "uno") return null
        val token = parts[1].substringBefore('?').substringBefore('\n').trim()
        if (!token.startsWith(".uno:")) return null
        return token.take(96)
    }

    /** True when this exact command can change revisions/document content. */
    fun isMutationCommand(commandName: String?): Boolean {
        if (commandName == null) return false
        val token = commandName.substringBefore('?').trim()
        return token in MUTATION_COMMANDS
    }

    private val MUTATION_COMMANDS = setOf(
        ".uno:AcceptTrackedChange",
        ".uno:AcceptTrackedChangeToNext",
        ".uno:RejectTrackedChange",
        ".uno:RejectTrackedChangeToNext",
        ".uno:AcceptTrackedChanges",
        ".uno:RejectTrackedChanges",
        ".uno:AcceptAllTrackedChanges",
        ".uno:RejectAllTrackedChanges",
        ".uno:ReinstateTrackedChange",
    )

    /** A matching `statechanged:` fact that may acknowledge [action]. */
    fun acknowledges(action: OfficeRevisionAction, commandName: String): Boolean {
        if (commandName !in observedCommands) return false
        return when (action) {
            OfficeRevisionAction.TOGGLE_RECORDING -> commandName == ".uno:TrackChanges"
            OfficeRevisionAction.SHOW_CHANGES -> commandName == ".uno:ShowTrackedChanges"
            OfficeRevisionAction.ACCEPT_CURRENT,
            OfficeRevisionAction.ACCEPT_NEXT -> commandName == ".uno:AcceptTrackedChange" ||
                commandName == ".uno:AcceptTrackedChangeToNext" ||
                commandName == ".uno:AcceptTrackedChanges"

            OfficeRevisionAction.REJECT_CURRENT,
            OfficeRevisionAction.REJECT_NEXT -> commandName == ".uno:RejectTrackedChange" ||
                commandName == ".uno:RejectTrackedChangeToNext" ||
                commandName == ".uno:RejectTrackedChanges"

            OfficeRevisionAction.ACCEPT_ALL -> commandName == ".uno:AcceptAllTrackedChanges" ||
                commandName == ".uno:AcceptTrackedChanges"

            OfficeRevisionAction.REJECT_ALL -> commandName == ".uno:RejectAllTrackedChanges" ||
                commandName == ".uno:RejectTrackedChanges"

            OfficeRevisionAction.PREVIOUS -> commandName == ".uno:PreviousTrackedChange"
            OfficeRevisionAction.NEXT -> commandName == ".uno:NextTrackedChange"
        }
    }
}
