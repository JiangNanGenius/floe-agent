// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Android-free view of one resolved accessibility surface (the active window's
 * root, or one window of the service's interactive window set) so credential
 * surface readiness is decided by a pure, deterministically testable selection.
 *
 * Implementations read metadata only. Nothing here ever exposes node text,
 * bounds, window identifiers, display identifiers or credential material; the
 * closed [SurfaceStage] labels are the only externally visible outcome, so a
 * real device trace says which readiness layer failed without any values.
 */
internal interface SurfaceCandidate {
    /**
     * The tree provably belongs to the default display. Window-backed
     * candidates check the platform-reported display id; the active-root
     * candidate checks membership in the interactive default-display window
     * set. Where the platform cannot report it, the documented contract that
     * the interactive window set is default-display-only is trusted.
     */
    val onDefaultDisplay: Boolean

    /** A content tree was freshly retrieved; false covers absent or non-retrievable roots. */
    val contentAvailable: Boolean

    /** The retrieved root itself reports the native SystemUI package. */
    val trustedSystemUiRoot: Boolean

    /** The root and its window still agree (a detached or mismatched tree is stale). */
    val lifecycleConsistent: Boolean

    /** The owning window carries the active or input-focused role. */
    val inputFocused: Boolean

    /**
     * Bounded node probe for a credential field, a labelled submit control or
     * keypad digits. Only ever called after every trust gate above has passed,
     * and never for a log: the return is a single boolean.
     */
    fun showsCredentialContent(): Boolean
}

/** Closed readiness labels. Exactly these strings may ever reach a trace. */
internal enum class SurfaceStage {
    /** The display is not actually interactive; no surface is input-trustworthy. */
    DISPLAY_IDLE,
    /** rootInActiveWindow returned null. */
    ACTIVE_ROOT_ABSENT,
    /** The active root belongs to a package other than native SystemUI. */
    ACTIVE_ROOT_FOREIGN,
    /** The active root reports no owning window; treated as a stale tree. */
    ACTIVE_ROOT_STALE,
    /** The active root is SystemUI but not on the trusted default display. */
    ACTIVE_ROOT_FOREIGN_DISPLAY,
    /** The active root is trusted and current but shows no credential surface yet. */
    ACTIVE_ROOT_NO_SURFACE,
    /** No interactive default-display windows were reported at all. */
    WINDOWS_EMPTY,
    /** Reported default-display windows have no retrievable content roots. */
    WINDOWS_NO_CONTENT,
    /** Reported content roots all belong to non-SystemUI packages. */
    WINDOWS_FOREIGN,
    /** SystemUI roots exist but their window/root agreement is broken (stale trees). */
    WINDOWS_STALE,
    /** A live trusted SystemUI window exists; its credential surface is not yet displayed. */
    WINDOW_SURFACE_PENDING,
    /** A trusted credential surface resolved through the active root (preserved fast path). */
    SURFACE_READY_ACTIVE_ROOT,
    /** A trusted credential surface resolved from exactly one eligible window. */
    SURFACE_READY_WINDOW,
    /** Two or more eligible SystemUI credential surfaces with no unique focus winner. */
    SURFACE_AMBIGUOUS,
}

/**
 * The observation of one readiness poll: context stages explain why the active
 * root alone was insufficient; the outcome is the terminal decision.
 * [windowIndex] refers to the original caller-supplied window order and is only
 * meaningful for [SurfaceStage.SURFACE_READY_WINDOW].
 */
internal class SurfaceObservation(
    val context: List<SurfaceStage>,
    val outcome: SurfaceStage,
    val windowIndex: Int = -1,
) {
    /** Fixed-label trace text; contains no identifiers, counts or values. */
    fun traceText(): String = (context + outcome).joinToString(" ") { it.name }
}

/**
 * Pure default-display SystemUI credential surface selection:
 * 1. An un-interactive display decides everything (never input into sleep).
 * 2. A current, trusted default-display active root that already shows the
 *    credential surface is the preserved fast path and short-circuits the scan.
 * 3. Otherwise the actually reported window set decides: only windows on the
 *    default display with a freshly retrieved, SystemUI-owned, lifecycle-
 *    consistent root qualify; of those, exactly one showing credential content
 *    resolves, none means the real SystemUI surface is still pending, and more
 *    than one needs a unique active/focused winner or the surface is refused
 *    as ambiguous (never guessed, never typed into a stale or foreign tree).
 */
internal fun selectCredentialSurface(
    displayInteractive: Boolean,
    activeRoot: SurfaceCandidate?,
    windows: List<SurfaceCandidate>,
): SurfaceObservation {
    if (!displayInteractive) return SurfaceObservation(emptyList(), SurfaceStage.DISPLAY_IDLE)
    val context = ArrayList<SurfaceStage>(1)
    if (activeRoot == null) {
        context += SurfaceStage.ACTIVE_ROOT_ABSENT
    } else {
        when {
            !activeRoot.trustedSystemUiRoot -> context += SurfaceStage.ACTIVE_ROOT_FOREIGN
            !activeRoot.lifecycleConsistent -> context += SurfaceStage.ACTIVE_ROOT_STALE
            !activeRoot.onDefaultDisplay -> context += SurfaceStage.ACTIVE_ROOT_FOREIGN_DISPLAY
            !activeRoot.contentAvailable -> context += SurfaceStage.ACTIVE_ROOT_ABSENT
            activeRoot.showsCredentialContent() ->
                return SurfaceObservation(emptyList(), SurfaceStage.SURFACE_READY_ACTIVE_ROOT)
            else -> context += SurfaceStage.ACTIVE_ROOT_NO_SURFACE
        }
    }
    if (windows.isEmpty()) return SurfaceObservation(context, SurfaceStage.WINDOWS_EMPTY)
    val indexed = windows.withIndex().toList()
    val defaults = indexed.filter { it.value.onDefaultDisplay }
    if (defaults.isEmpty()) return SurfaceObservation(context, SurfaceStage.WINDOWS_EMPTY)
    val withContent = defaults.filter { it.value.contentAvailable }
    if (withContent.isEmpty()) return SurfaceObservation(context, SurfaceStage.WINDOWS_NO_CONTENT)
    val systemUi = withContent.filter { it.value.trustedSystemUiRoot }
    if (systemUi.isEmpty()) return SurfaceObservation(context, SurfaceStage.WINDOWS_FOREIGN)
    val alive = systemUi.filter { it.value.lifecycleConsistent }
    if (alive.isEmpty()) return SurfaceObservation(context, SurfaceStage.WINDOWS_STALE)
    val showing = alive.filter { it.value.showsCredentialContent() }
    if (showing.isEmpty()) return SurfaceObservation(context, SurfaceStage.WINDOW_SURFACE_PENDING)
    if (showing.size == 1) return SurfaceObservation(context, SurfaceStage.SURFACE_READY_WINDOW, showing.first().index)
    val focused = showing.filter { it.value.inputFocused }
    return if (focused.size == 1)
        SurfaceObservation(context, SurfaceStage.SURFACE_READY_WINDOW, focused.first().index)
    else
        SurfaceObservation(context, SurfaceStage.SURFACE_AMBIGUOUS)
}

/**
 * A trusted SystemUI node may act only through an ACTION_CLICK the platform
 * actually offers it, even where OEM clickable metadata disagrees. Disabled
 * nodes and nodes without either signal are never clicked, and no inferred
 * screen coordinate is ever used.
 */
internal fun acceptsNativeClickAction(enabled: Boolean, clickable: Boolean, offersClick: Boolean): Boolean =
    enabled && (clickable || offersClick)

/**
 * Closed outcomes of the ONE pre-reveal readiness observation: the actual
 * default-display power state plus the trusted native SystemUI window presence
 * that must be genuinely observed before the single reveal swipe may be
 * dispatched. Like [SurfaceStage] these labels carry no identifiers, counts,
 * text or content; they exist so a real run can prove which readiness layer
 * decided. An uncertain read always lands on a not-ready outcome.
 */
internal enum class PhoneRevealReadiness {
    /** A unique trusted credential surface resolved: enter it, never swipe over it. */
    CREDENTIAL_VISIBLE,
    /** The default display is genuinely on and interactive AND a live, trusted,
     * default-display SystemUI window is reported while showing no credential
     * surface yet. The only outcome on which the one reveal swipe legitimately acts. */
    REVEAL_READY,
    /** The actual default-display power state is not awake/interactive. */
    DISPLAY_IDLE,
    /** The display is awake but no trusted live SystemUI window is reported:
     * empty, foreign, stale or content-less window sets, and ambiguous multiple
     * credential surfaces all collapse here — nothing is swiped or typed blind. */
    SYSTEM_UI_PENDING,
}

/**
 * Pure mapping from one fresh power observation plus one fresh
 * [selectCredentialSurface] observation to the single pre-reveal readiness
 * outcome. Power decides first (never scan or swipe into a sleeping panel);
 * an awake panel then decides strictly on the observed window outcome, so a
 * deadline, an accepted wake request or a lease alone can never qualify.
 */
internal fun mapRevealReadiness(
    displayPowerOn: Boolean,
    observation: SurfaceObservation,
): PhoneRevealReadiness {
    if (!displayPowerOn) return PhoneRevealReadiness.DISPLAY_IDLE
    return when (observation.outcome) {
        SurfaceStage.DISPLAY_IDLE -> PhoneRevealReadiness.DISPLAY_IDLE
        SurfaceStage.SURFACE_READY_ACTIVE_ROOT, SurfaceStage.SURFACE_READY_WINDOW ->
            PhoneRevealReadiness.CREDENTIAL_VISIBLE
        SurfaceStage.WINDOW_SURFACE_PENDING -> PhoneRevealReadiness.REVEAL_READY
        else -> PhoneRevealReadiness.SYSTEM_UI_PENDING
    }
}
