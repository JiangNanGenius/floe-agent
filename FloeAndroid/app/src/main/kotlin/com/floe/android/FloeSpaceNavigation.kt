// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import com.floe.android.design.MoreDestination
import com.floe.android.design.SidebarSelection

/**
 * The FULL-channel phone-access settings section key (G08). It is a STABLE
 * external key, not a settings enum name, and it exists only while
 * `DistributionSettingsFeature.sections()` is actually wired by the device
 * access host. Space never invents this page or its availability.
 */
internal const val FLOE_PHONE_ACCESS_SECTION_KEY: String = "x:phone_access"

/**
 * The Space sections: the four iOS `SpaceRootView` sections plus the
 * Android-only phone workspace. Space is a navigation surface only: no
 * section carries a workspace or task identity, and every destination it
 * opens is an existing App surface.
 */
internal enum class FloeSpaceSection(val key: String) {
    OVERVIEW("overview"),
    NOTES("notes"),
    FILES("files"),
    TOOLBOX("toolbox"),
    /** FULL-channel phone workspace; visible only while its real settings
     * section is wired. */
    PHONE("phone"),
    ;

    companion object {
        val default: FloeSpaceSection = OVERVIEW

        /** Unknown/missing saved values open Overview, never another section. */
        fun fromKey(key: String?): FloeSpaceSection =
            entries.firstOrNull { it.key == key } ?: default
    }
}

/**
 * The visible Space sections in product order. The four iOS sections keep
 * their order; the Android-only Phone workspace sits directly after Overview
 * and is omitted entirely while its real content is not wired.
 */
internal fun floeSpaceSections(phoneAccessAvailable: Boolean): List<FloeSpaceSection> =
    if (phoneAccessAvailable) {
        listOf(
            FloeSpaceSection.OVERVIEW,
            FloeSpaceSection.PHONE,
            FloeSpaceSection.NOTES,
            FloeSpaceSection.FILES,
            FloeSpaceSection.TOOLBOX,
        )
    } else {
        listOf(
            FloeSpaceSection.OVERVIEW,
            FloeSpaceSection.NOTES,
            FloeSpaceSection.FILES,
            FloeSpaceSection.TOOLBOX,
        )
    }

/**
 * Toolbox rows map one-to-one onto destinations the shell already renders.
 * Keeping the mapping here (instead of inline click lambdas) pins that Space
 * never advertises a route without an implementation.
 */
internal enum class FloeSpaceToolboxTarget(val selection: SidebarSelection) {
    DEVICES(SidebarSelection.More(MoreDestination.DEVICES)),
    SYSTEM_SERVICES(SidebarSelection.More(MoreDestination.SYSTEM_SERVICES)),
    NETWORK(SidebarSelection.More(MoreDestination.NETWORK)),
    REMOTE(SidebarSelection.More(MoreDestination.REMOTE)),
}

/**
 * Optional Space entries are rendered ONLY when their owning service supplied
 * a real entry point. Today that is the Office document picker and the
 * meeting service; a null callback removes the row instead of drawing a
 * disabled or fabricated action.
 */
internal fun spaceOptionalEntryVisible(action: (() -> Unit)?): Boolean = action != null

/**
 * A project can be created only when the runtime host is present and its
 * durable store is not reporting `runtime_unavailable`, and no project
 * command is already in flight. This keeps the Files action live, never a
 * button that silently does nothing.
 */
internal fun spaceCanCreateProject(
    hasRuntime: Boolean,
    runtimeUnavailable: Boolean,
    busy: Boolean,
): Boolean = hasRuntime && !runtimeUnavailable && !busy
