// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

/**
 * Typed rejection raised by the S11 Skills-folder staging JNI adapter. Only
 * the numeric contract status is retained — staging roots, receipts, URIs,
 * display names and file bytes NEVER enter the message.
 *
 * Status space (owned by `SkillsFolderHostStatus` in Swift; deliberately
 * DISJOINT from the frozen runtime-owner -2xx space and the attachment
 * -3xx space, mirroring how each is itself additive):
 *   0 ok, -400 invalidArguments, -401 notInstalled,
 *   -402 epochFenced, -403 routeUnknown, -404 treeUnknown,
 *   -405 fileUnknown, -406 pathUnsafe, -407 duplicatePath,
 *   -408 fileCountExceeded, -409 bytesExceeded, -410 depthExceeded,
 *   -411 diskFull, -412 writeFailed, -413 aborted,
 *   -414 digestMismatch, -415 receiptRefused, -416 saturated,
 *   -417 bufferTooSmall, -499 internal.
 */
class SkillsFolderStagingNativeException(val status: Int) :
    IllegalStateException("folder_staging_status_$status")

/**
 * External declarations only (no logic) for the S11 trusted Skills-folder
 * staging channel. The class initializer loads libfloe_jni (idempotent per
 * class loader; same library object the gateway, runtime-owner and
 * attachment loaders already pin). Production callers touch this object
 * only from the staging controller's worker coroutine — never from a
 * property initializer or Application main.
 *
 * Discipline (identical to the accepted attachment channel):
 *  * receipts are strict ASCII opaque handles; the Java strings are
 *    validated in C before crossing and never contain a path;
 *  * bytes are pushed in bounded chunks (<= 64 KiB) with no whole-file
 *    buffering, no base64, no JSON;
 *  * the relative path handed to `folderFileBegin` is validated by BOTH
 *    the JVM-side safety pass and the native channel (segment/dup/depth/
 *    bounds), and the domain re-validates the final tree itself;
 *  * a late result under a retired Root generation is refused (-402), it
 *    never acts on a newer one;
 *  * the ONLY install-eligible output is the domain-minted `stg:v1:`
 *    receipt from `folderTreeFinish` (registered through
 *    `SkillsDomain.registerStagedFolder` against the real on-disk
 *    inventory). Arrival never installs anything.
 */
object SkillsFolderStagingNative {
    init { System.loadLibrary("floe_jni") }

    /**
     * Register one captured folder-staging route with the trusted native
     * host. [incarnation] is the controller's monotonic request owner;
     * [uiGeneration] is the shared host UI admission value captured at
     * presentation; [rootEpoch] is the ACTUAL native Root epoch the request
     * was launched under. A retired/foreign epoch refuses (-402/-403).
     * Returns the opaque route receipt (`sfk:v1:<32hex>`).
     */
    external fun folderRouteOpen(
        incarnation: Long,
        uiGeneration: Long,
        rootEpoch: Long,
    ): String

    /** Invalidate one route: aborts that route's live trees/ingresses only
     *  (the owned scratch copies are removed; nothing else is touched). */
    external fun folderRouteClose(routeReceipt: String)

    /**
     * Allocate the domain-owned scratch tree directory for one picked
     * folder (`SkillsDomain.hostCreateStagingDirectory` under the domain's
     * staging root) and register its live copy session.
     * [displayNameHint] is a CLAMPED display hint only — never a path.
     * Returns the opaque tree handle (`sft:v1:<32hex>`).
     */
    external fun folderTreeOpen(routeReceipt: String, displayNameHint: String?): String

    /** Begin one file of the tree at a host-walked RELATIVE path. Native
     *  re-checks segment safety, the duplicate collision set, the count/
     *  byte/depth budgets and the current epoch before creating the file.
     *  Returns the opaque file handle (`sfi:v1:<32hex>`). */
    external fun folderFileBegin(treeHandle: String, relativePath: String): String

    /** One bounded chunk of the actual source stream. Throws typed
     *  [SkillsFolderStagingNativeException] on refusal. */
    external fun folderFileWrite(
        fileHandle: String,
        data: ByteArray,
        offset: Int,
        length: Int,
    )

    /** EOF: flush + fsync this file. */
    external fun folderFileEnd(fileHandle: String)

    /** Fast host abort of a live file (partial bytes removed). */
    external fun folderFileAbort(fileHandle: String)

    /**
     * Finish the tree: native flushes, then computes the ORIGINAL
     * canonical digest over the ACTUAL disk inventory and calls
     * `SkillsDomain.registerStagedFolder(directory:receipt:now:)` with the
     * real fileCount/totalBytes/TTL. Returns "<stg:v1:…> <fileCount>
     * <totalBytes>" — three space-separated ASCII tokens, all
     * domain-minted (never a path). A mismatch or shape refusal throws
     * typed (-414/-415) and the owned directory is removed.
     */
    external fun folderTreeFinish(treeHandle: String, displayNameHint: String?): String

    /** Abort the whole tree: the owned scratch directory is removed
     *  (recoverable cleanup of THIS tree only). */
    external fun folderTreeAbort(treeHandle: String)

    /** Lock-only bounded counters JSON (routes/trees/bytes; no paths,
     *  names or URIs). Null only when the Swift side cannot serialize;
     *  callers treat null as unknown, never as ready. */
    external fun folderStagingStatus(): String?
}
