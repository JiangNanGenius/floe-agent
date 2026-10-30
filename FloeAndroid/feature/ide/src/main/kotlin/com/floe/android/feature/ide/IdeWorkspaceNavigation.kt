// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.ide

import com.floe.android.design.FloeLayout

/**
 * Compact navigation level for the phone file-list-first flow.
 *
 * This is chrome/navigation state only. The active document, tabs, drafts,
 * undo/redo lineage and recovery projections remain the presenter's single
 * authority and are never duplicated here.
 */
public enum class IdeCompactLevel {
    /** Compact root: the workspace file list. */
    FILE_LIST,

    /** A file is presented in the editor; Back returns to the list. */
    EDITOR,
}

/**
 * Explicit presentation policy for the IDE surface.
 *
 * Phone list-first navigation is a property of the ACTUAL window, never of a
 * narrow child alone: the 430dp inspector column on a tablet window keeps its
 * existing compact editor root (the tree stays behind the folder control),
 * while a real phone window roots the IDE at the file list. A caller that
 * cannot supply the window width (debug previews, component hosts) gets the
 * pre-existing layout instead of a guessed phone mode.
 */
public object IdeWorkspacePresentation {
    /** True only for a window below the tablet boundary. */
    public fun isPhoneWindow(windowWidthDp: Float?, smallestWindowWidthDp: Float? = null): Boolean =
        FloeLayout.usesCompactNavigation(windowWidthDp, smallestWindowWidthDp)

    /**
     * Whether this composition should use the phone file-list-first levels.
     *
     * @param windowWidthDp actual window width in dp, or null when unknown.
     * @param paneWidthDp measured IDE pane width in dp.
     */
    public fun usesPhoneFileList(windowWidthDp: Float?, paneWidthDp: Float, smallestWindowWidthDp: Float? = null): Boolean =
        isPhoneWindow(windowWidthDp, smallestWindowWidthDp) &&
            (paneWidthDp < FloeLayout.PersistentTwoColumnMinWidth.value ||
                (smallestWindowWidthDp != null && smallestWindowWidthDp > 0f &&
                    smallestWindowWidthDp < FloeLayout.PersistentTwoColumnMinWidth.value))

    /**
     * Back destination policy. On the phone file list, Back leaves the
     * workspace and returns to the owning task; from the phone editor it
     * returns to the list first. Tablet panes and the wide split keep their
     * existing single-level dismiss semantics.
     */
    public fun backReturnsToTask(phoneListFirst: Boolean, level: IdeCompactLevel): Boolean =
        !phoneListFirst || level == IdeCompactLevel.FILE_LIST
}
