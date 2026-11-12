// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

/**
 * Closed parser for the OPTIONAL `device.observe.source` field.
 *
 * `auto` preserves the default useful-Accessibility preference. `adb` selects
 * the already-authorized ADB structured UI tier for a NEW observation; it does
 * not grant it. The field is deliberately limited to a new observation: a
 * retained observation id remains pinned to the backend that produced it, so
 * it can never silently switch source while paging.
 */
internal enum class DeviceObserveSource { AUTO, ADB }

internal object DeviceObserveSourcePolicy {

    sealed interface Decision {
        /** A new observation may use this source. */
        data class New(val source: DeviceObserveSource) : Decision

        /** Paging a retained observation; the source is the original one. */
        data object Paging : Decision

        /** Unknown value or an attempt to switch a retained observation. */
        data object Invalid : Decision
    }

    fun decide(rawSource: Any?, hasObservationId: Boolean): Decision {
        val source = when (rawSource) {
            null -> DeviceObserveSource.AUTO
            is String -> when (rawSource) {
                "auto" -> DeviceObserveSource.AUTO
                "adb" -> DeviceObserveSource.ADB
                else -> return Decision.Invalid
            }
            else -> return Decision.Invalid
        }
        if (hasObservationId) {
            return if (source == DeviceObserveSource.AUTO) Decision.Paging else Decision.Invalid
        }
        return Decision.New(source)
    }
}
