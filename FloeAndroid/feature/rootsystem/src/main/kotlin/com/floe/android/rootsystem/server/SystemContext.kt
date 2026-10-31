// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.os.Looper

/**
 * The Floe server is launched by app_process, not as an Android Application, so
 * it has no Context until the system ActivityThread is created. This is the same
 * bootstrap role performed by Shizuku's hidden-compat bridge. The process is not
 * a sandboxed App process, but hidden-API enforcement still varies by OEM; a
 * failure is surfaced as a typed startup error instead of pretending to work.
 */
internal object SystemContext {

    @Volatile
    private var cached: Context? = null

    fun get(): Context {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            if (Looper.getMainLooper() == null) Looper.prepareMainLooper()
            // ActivityThread is a hidden platform class; reflect so the module
            // compiles against the public android.jar and fails actionably if an
            // OEM removes the bootstrap. This process is not an App (no target
            // SDK/package), but some OEMs still enable hidden-API filtering; the
            // exemption is scoped to the ActivityThread bootstrap only and is
            // best-effort - a real failure surfaces as a typed startup error.
            exemptActivityThread()
            val type = Class.forName("android.app.ActivityThread")
            val systemMain = type.getDeclaredMethod("systemMain").apply { isAccessible = true }
            val thread = systemMain.invoke(null)
            val getSystemContext = type.getDeclaredMethod("getSystemContext").apply { isAccessible = true }
            val context = getSystemContext.invoke(thread) as Context
            cached = context
            return context
        }
    }

    private fun exemptActivityThread() {
        try {
            val runtimeType = Class.forName("dalvik.system.VMRuntime")
            val runtime = runtimeType.getDeclaredMethod("getRuntime").invoke(null)
            val setExemptions = runtimeType.getDeclaredMethod(
                "setHiddenApiExemptions",
                Array<String>::class.java,
            )
            setExemptions.invoke(runtime, arrayOf("Landroid/app/ActivityThread;", "Landroid/app/ActivityThread$"))
        } catch (_: Throwable) {
            // Non-app app_process usually needs no exemption; leave a missing
            // platform method to the ActivityThread call below to surface.
        }
    }
}
