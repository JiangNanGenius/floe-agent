package com.floe.android.core.officeengine

/**
 * Public, module-level entry point for the G05-R1 embedded Office engine.
 *
 * Trust model (R1):
 *  - The viewer accepts ONLY trusted, App-staged private snapshots: a regular
 *    file already inside this application's own data area, plus the host's
 *    session identity and the source digest the App stager verified. Caller
 *    input can never grant permissions, reach outside the app data roots, or
 *    open an arbitrary path: the engine process re-canonicalises and re-hashes
 *    the staged file before any native work (fail-closed).
 *  - The viewer Activity and engine Service are NOT exported and live in the
 *    dedicated `:floe_office` process (same UID = lifecycle/crash
 *    segregation, NOT a security sandbox). FloeApplication must skip the
 *    default-process bootstrap in that process (Main-owned host change).
 *  - R1 (default) is preview/read-only: editing, saving, export and print
 *    routes stay gated OFF at the message boundary and surface as honest
 *    outcomes, not silently accepted requests. R2 adds an EXPLICIT
 *    trusted-host EDIT permission over a separately owned mutable working
 *    copy plus typed save/export receipts (OfficeSaveReceipt): native saves
 *    write ONLY the module-owned working copy or a module-private staged
 *    output — never a user/provider original — and success is attested only
 *    by the pinned producer's real callbacks plus post-write file
 *    verification. Macro-bearing containers and the engine's
 *    macro/remote-refresh message paths remain blocked (CoolMessageGate);
 *    engine-kernel auto-execution itself remains a device-verification item,
 *    honestly unproven statically.
 */
object OfficeEngine {
    /** Exact process name the module manifest pins for Activity + Service + init provider. */
    const val PROCESS_OFFICE: String = ":floe_office"

    /** Stable WebView data-directory suffix for the :floe_office process. */
    const val WEBVIEW_DATA_SUFFIX: String = "floe_office"

    /**
     * Version of the fenced typed precision surface (G05-R2 P-A): structured
     * target capture/readback and native mutation dispatch through
     * [OfficeEngineCommandsPolicy.TRANSACTION_POST_PRECISION_COMMAND] /
     * [OfficeEngineCommandsPolicy.TRANSACTION_READ_PRECISION_ANSWER] and the
     * `com.floe.android.core.officeengine.precision` contract types. Bump on
     * any breaking change to the precision request/result/answer shapes.
     */
    const val PRECISION_API_VERSION: Int = 1

    /**
     * True when the pinned payload metadata is compiled into this build.
     * It never claims that the native engine loaded or rendered:
     * [availability] reports the real observed state.
     */
    const val PAYLOAD_VERSION: String = BuildConfig.OFFICE_PAYLOAD_VERSION
    const val PAYLOAD_BUILD_ID: String = BuildConfig.OFFICE_PAYLOAD_BUILD_ID

    /**
     * Idempotent WebView data-directory bootstrap for the :floe_office
     * process. The library ContentProvider declared in the module manifest
     * already calls this in that process BEFORE any component code runs, so
     * embedders normally never call it. Public so Main's future in-process
     * embedding path can honour the ordering explicitly; after the first
     * WebView is created in a process this can no longer succeed and the
     * return value is false (never silently ignored).
     */
    fun ensureOfficeWebViewDirectory(): Boolean = OfficeWebViewDirectory.ensureOnce()

    /** Observed readiness. No field here implies document rendering proof. */
    fun availability(context: android.content.Context): OfficeAvailability =
        OfficeAvailability.of(context)

    /**
     * Explicit Intent for the module viewer. Launch from the App process;
     * the system starts/attaches the :floe_office process. Read the outcome
     * from [RESULT_EXTRA_*] via the standard Activity result contract.
     */
    fun previewIntent(
        context: android.content.Context,
        request: OfficePreviewRequest,
    ): android.content.Intent =
        OfficePreviewActivity.intentFor(context, request)

    /**
     * R2 viewer Intent carrying the exact-session capabilities the App host
     * mints (all optional; a null capability simply disables that channel):
     *  - [closeAck]: the [OfficeCloseAck.parentBinder] endpoint so an exact
     *    user close is acknowledged BEFORE the fatal native BYE;
     *  - [viewerIncarnation]: the parent-minted opaque incarnation id fencing
     *    that acknowledgement;
     *  - [hostSaveChannel]: the [OfficeHostSaveChannel.parentBinder]
     *    endpoint for the generic save-target handoff (the App prepares the
     *    CREATE_DOCUMENT Intent; the FOREGROUND viewer Activity launches it
     *    and forwards the actual URI + returned flags back — the module
     *    never touches SAF itself) and for cross-process receipt/edit-state
     *    events.
     *
     * Live save/edit COMMANDS from the App process go through
     * [OfficeEngineCommands.bindIntent] + bindService (same UID, explicit,
     * non-exported), fenced by exact session token + mount generation. The
     * fenced typed PRECISION surface (structured target capture/readback
     * and native mutation dispatch, G05-R2 P-A) rides the SAME command
     * binding via [OfficeEngineCommands.postPrecisionCommand] /
     * [OfficeEngineCommands.readPrecisionAnswer]; see
     * `com.floe.android.core.officeengine.precision` for the typed contract
     * and its honest completion states.
      *  - [approvalNotice]: the [OfficeApprovalNotice.parentBinder] endpoint
      *    so the FOREGROUND viewer can ask (read-only, while resumed) whether
      *    its OWNING conversation currently holds a captured pending
      *    approval — the banner answer keeps Ask-first approvals reachable
      *    without closing the owned document (G05-R3 office-approval107).
      *    Present only for owned opens; the query grants nothing.
      *  - [reviewComponent]: the App-minted ComponentName the banner's Review
      *    action brings to the front with FLAG_ACTIVITY_REORDER_TO_FRONT
      *    (the existing chat Activity; the document stays open underneath).
      */
     fun viewerIntent(
        context: android.content.Context,
        request: OfficePreviewRequest,
        closeAck: android.os.IBinder? = null,
        viewerIncarnation: Long = -1L,
        hostSaveChannel: android.os.IBinder? = null,
        approvalNotice: android.os.IBinder? = null,
        reviewComponent: android.content.ComponentName? = null,
        /**
         * R3 internal Notes save: this App host owns a private working-copy
         * commit and accepts
         * [OfficeHostSaveHandoffPolicy.TRANSACTION_INTERNAL_SAVE]. The
         * viewer then offers "Save and close" on the dirty sheet (real
         * `.uno:Save` flush, App-owned destination) without a system file
         * picker; the ordinary Save Copy/export menu is unaffected. Shape
         * only — the actual capability is the same-UID [hostSaveChannel].
         */
        internalSave: Boolean = false,
    ): android.content.Intent =
        OfficePreviewActivity.intentFor(context, request).apply {
            // An IBinder is NOT a Parcelable: it travels through the Bundle's
            // putBinder/getBinder pair (API 18+), never putExtra (the R1
            // close-ack pattern). Ordinary longs stay putExtra.
            if (closeAck != null || hostSaveChannel != null || approvalNotice != null) {
                val capabilities = android.os.Bundle()
                if (closeAck != null) {
                    capabilities.putBinder(OfficeCloseAckPolicy.EXTRA_CLOSE_ACK, closeAck)
                    putExtra(OfficeCloseAckPolicy.EXTRA_VIEWER_INCARNATION, viewerIncarnation)
                }
                if (hostSaveChannel != null) {
                    capabilities.putBinder(
                        OfficeEngineCommandsPolicy.EXTRA_HOST_SAVE_CHANNEL,
                        hostSaveChannel,
                    )
                }
                if (approvalNotice != null) {
                    capabilities.putBinder(OfficeApprovalNoticePolicy.EXTRA_APPROVAL_NOTICE, approvalNotice)
                }
                putExtras(capabilities)
            } else if (viewerIncarnation > 0L) {
                putExtra(OfficeCloseAckPolicy.EXTRA_VIEWER_INCARNATION, viewerIncarnation)
            }
            // The App-owned review target travels as a plain Parcelable extra:
            // the module only forwards it to the banner action, never reads
            // its contents and never invents a navigation destination.
            if (reviewComponent != null) {
                putExtra(OfficeApprovalNoticePolicy.EXTRA_REVIEW_COMPONENT, reviewComponent)
            }
            if (internalSave) {
                putExtra(OfficeHostSaveHandoffPolicy.EXTRA_INTERNAL_SAVE, true)
            }
        }

        /**
         * G05-R3 office-return109: the INERT raise for the App's explicit
         * owned-document return strip. Component only — NO request extra, NO
         * capabilities, NO new mount semantics. The already-running viewer
         * instance is reordered to the front within its existing task
         * (document + owned editContext untouched; the Activity reads its
         * launch request only in onCreate and re-reads nothing on raise).
         * Concrete-instance correctness comes from the App side, NOT from
         * this Intent: Android selects the record synchronously during
         * startActivity handling, and the controller dispatches this raise
         * while holding its single-operation lock, so no settle or new
         * mount can interleave between the identity proof and the selection
         * (see OfficePreviewController.requestOwnedViewerRestore). If no
         * instance exists at selection, the module's own launch validation
         * fails this inert Intent closed immediately (missing-request
         * finish) — never a remount and never a different document opened.
         * NEW_TASK is required for application-context launches; the task
         * already holding the viewer is REUSED — never duplicated (no
         * MULTIPLE_TASK), never cleared (no CLEAR_TOP), and nothing is
         * finished by this path.
         */
        fun viewerRestoreIntent(context: android.content.Context): android.content.Intent =
            android.content.Intent(context, OfficePreviewActivity::class.java).apply {
                addFlags(
                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                        android.content.Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                )
            }
}

/** Honest, observation-only availability snapshot. */
data class OfficeAvailability(
    val payloadPinnedBuildId: String,
    val nativeLibraryDir: String?,
    val arm64Process: Boolean,
    val nativeLoadState: Int,
    val nativeLoadError: String?,
    val activeSession: String?,
) {
    internal companion object {
        fun of(context: android.content.Context): OfficeAvailability {
            val app = context.applicationInfo
            return OfficeAvailability(
                payloadPinnedBuildId = BuildConfig.OFFICE_PAYLOAD_BUILD_ID,
                nativeLibraryDir = app?.nativeLibraryDir,
                arm64Process = android.os.Process.is64Bit(),
                nativeLoadState = org.libreoffice.androidlib.LOActivity.nativeLoadState(),
                nativeLoadError = org.libreoffice.androidlib.LOActivity.nativeLoadError(),
                activeSession = OfficeEngineService.activeSessionTokenForDiagnostics(),
            )
        }
    }
}
