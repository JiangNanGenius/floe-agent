// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runlifecycle

/** Navigation only. These values never authorize a run, file or cancellation. */
object RunNotificationReturn {
    const val ACTION = "com.floe.android.runlifecycle.OPEN_TASK_CENTER"
    const val EXTRA_REQUEST_ID = "floe.notification.requestID"
}
