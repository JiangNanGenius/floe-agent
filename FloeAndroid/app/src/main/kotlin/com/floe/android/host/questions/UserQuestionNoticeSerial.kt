// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.questions

/** Serialize the OS notification side effect with its in-process identity. */
internal object UserQuestionNoticeSerial {
    private val lock = Any()

    fun <T> run(action: () -> T): T = synchronized(lock) { action() }
}
