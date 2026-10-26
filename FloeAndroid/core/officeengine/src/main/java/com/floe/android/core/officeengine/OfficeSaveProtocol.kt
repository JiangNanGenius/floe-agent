// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

/**
 * Pure contract for the pinned producer's in-place save (working-copy flush)
 * protocol. Every fact here is anchored in the pinned Collabora Online
 * revision 2333344185931274f9c49d6c12a408cefcef6844 (the exact source of the
 * shipped libandroidapp.so / coolwsd payload), NOT guessed:
 *
 *  - The client message `save dontTerminateEdit=N dontSaveIfUnmodified=M
 *    [extendedData=...]` is the real protocol command (wsd/ClientSession.cpp
 *    `tokens.equals(0, "save")` → DocumentBroker::manualSave → sendUnoSave
 *    rewrites it to `uno .uno:Save {DontTerminateEdit,DontSaveIfUnmodified}`).
 *    The official mobile app posts exactly this message from Java through
 *    postMobileMessageNative (upstream LOActivity.java onPause/onNewIntent:
 *    "save dontTerminateEdit=1 dontSaveIfUnmodified=1").
 *  - Completion arrives as the kit's UNO_COMMAND_RESULT callback for
 *    `.uno:Save` (kit/ChildSession.cpp loKitCallback): it sends
 *    `unocommandresult: {json}` toward the client — observable in Java at the
 *    native→page boundary (Session.onMessageToJs) BEFORE the page sees it —
 *    and, on Android mobile only when success=="true", also calls
 *    postDirectMessage("SAVE " + json) into Java (consumed as a diagnostic
 *    fact; never treated as proof on its own because the page shares the
 *    same Java entry point and could forge that string).
 *  - wsd/ClientSession.cpp (`unocommandresult:` branch) additionally stamps
 *    `isAutosave` into the JSON forwarded to the client.
 *  - Outcome semantics are the pinned common/SaveResult.hpp parse:
 *    success==true → Saved (core wrote a new version); success==false with
 *    result string "unmodified" → Unmodified (core wrote nothing, no error);
 *    anything else → Failed.
 *  - Failure paths also emit `error: cmd=save kind=savefailed` (session not
 *    writable, wsd/ClientSession.cpp) or `error: cmd=storage kind=savefailed`
 *    (DocumentBroker::handleSaveResponse on a Failed SaveResult).
 *
 * There is NO asynchronous saveAs acknowledgement in the pinned producer:
 * JNI saveAs (androidapp.cpp:302-316) calls LOKitDocument::saveAs directly
 * and returns void; the official app reads the target file immediately after
 * the call returns (upstream LOActivity.java REQUEST_SAVEAS_* flow). Export
 * proof is therefore "synchronous JNI return + real bounded output file
 * verification", handled in OfficeEngineService, never a void-success claim.
 */
object OfficeSaveProtocol {

    /** The kit UNO command name carried by save completion frames. */
    const val SAVE_COMMAND_NAME = ".uno:Save"

    /**
     * Builds the real protocol message for one working-copy flush.
     *
     * [saveIfUnmodified] false mirrors the official autosave hint
     * (`dontSaveIfUnmodified=1`: core answers "unmodified" without writing);
     * true forces core to write a new version even when the document carries
     * no changes (`dontSaveIfUnmodified=0`), which makes FLUSHED receipts
     * deterministic for explicit user saves. dontTerminateEdit stays 1: an
     * explicit save must never tear the user out of editing.
     */
    fun flushMessage(saveIfUnmodified: Boolean): String =
        "save dontTerminateEdit=1 dontSaveIfUnmodified=" + (if (saveIfUnmodified) 1 else 0)

    /** Pinned SaveResult.hpp outcome mapping. */
    enum class NativeSaveOutcome {
        /** success==true: core wrote a new version of the document. */
        WRITTEN,

        /** success==false + result "unmodified": core wrote nothing; not an error, not a new version. */
        UNMODIFIED_SKIPPED,

        /** success==false with any other (or no) result: core tried and could not write. */
        FAILED,
    }

    /**
     * Maps one parsed `.uno:Save` unocommandresult frame to the pinned
     * outcome. A frame whose success field could not be parsed at all is
     * NOT mapped (returns null): an unparseable frame is never evidence.
     */
    fun outcome(success: Boolean?, resultValue: String?): NativeSaveOutcome? = when {
        success == null -> null
        success -> NativeSaveOutcome.WRITTEN
        resultValue == "unmodified" -> NativeSaveOutcome.UNMODIFIED_SKIPPED
        else -> NativeSaveOutcome.FAILED
    }

    /**
     * True for the native error frames that describe a failed save attempt
     * (never a load/render failure): `cmd=save` refusals from the session
     * layer and `cmd=storage kind=savefailed` from the save-response path.
     */
    fun isSaveRelatedError(cmd: String?, kind: String?): Boolean =
        cmd == "save" || (cmd == "storage" && kind == "savefailed")
}
