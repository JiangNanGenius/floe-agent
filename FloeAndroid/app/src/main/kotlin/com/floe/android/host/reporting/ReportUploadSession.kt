// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.reporting

import java.io.IOException
import okhttp3.Call

/** Revocable owner of one report attempt, including preparation before HTTP. */
internal class ReportUploadSession {
    private val gate = Any()
    private var cancelled = false
    private var call: Call? = null

    fun checkActive() {
        if (synchronized(gate) { cancelled }) throw ReportUploadCancelled()
    }

    fun bind(value: Call) {
        val admitted = synchronized(gate) {
            check(call == null)
            if (cancelled) false else { call = value; true }
        }
        if (!admitted) { value.cancel(); throw ReportUploadCancelled() }
    }

    fun unbind(value: Call) = synchronized(gate) {
        if (call === value) call = null
    }

    fun cancel() {
        val active = synchronized(gate) { cancelled = true; call }
        active?.cancel()
    }
}

internal class ReportUploadCancelled : IOException("report_cancelled")
