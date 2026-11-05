package com.floe.android.core.officeengine

/** Installed signed-split loading is supplied by the Application in each
 * non-isolated process. No downloaded library path or model value is accepted. */
object OfficeNativePayload {
    @Volatile private var installedApk: (() -> String)? = null
    fun attachApk(provider: () -> String) { installedApk = provider }
    internal fun apkFile(context: android.content.Context): String = installedApk?.invoke() ?: context.packageResourcePath
    @Volatile private var loadInstalled: (() -> Unit)? = null
    fun attach(loader: () -> Unit) { loadInstalled = loader }
    internal fun load() {
        val loader = loadInstalled
        if (loader != null) loader() else System.loadLibrary("androidapp")
    }
}
