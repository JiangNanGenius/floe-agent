// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

/**
 * Pure owner binding for service commands and notification PendingIntents.
 * A command is valid only when it names the exact active meeting and recording
 * generation. This prevents a stale notification or a delayed timeout cleanup
 * from pausing/stopping/discarding a newer take.
 */
internal object MeetingRecordingCommandBinding {
    fun matches(
        intentMeetingId: String?,
        intentRecordingId: String?,
        ownerMeetingId: String?,
        ownerRecordingId: String?,
        ownerActive: Boolean,
    ): Boolean {
        if (!ownerActive) return false
        if (intentMeetingId == null || intentRecordingId == null) return false
        if (ownerMeetingId == null || ownerRecordingId == null) return false
        return intentMeetingId == ownerMeetingId && intentRecordingId == ownerRecordingId
    }
}
