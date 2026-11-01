// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.Process
import java.lang.reflect.Field
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method

/**
 * Calls the App-owned publication provider from the privileged server process.
 *
 * The server is started by app_process, not by zygote, and
 * `ActivityThread.systemMain()` never calls `attachApplication()`, so
 * ActivityManagerService has no ProcessRecord for it. A normal
 * `ContentResolver.call()` therefore makes
 * `ContentProviderHelper#getContentProviderImpl` fail with
 * "Unable to find app for caller ... when getting content provider" (Android
 * 13). The resolver wraps that in an exception the publisher cannot distinguish
 * from any other I/O failure, so publication retried invisibly and the App saw
 * only its own `binder_timeout`.
 *
 * The platform gives the shell/root identities a supported external entry
 * point instead: `IActivityManager.getContentProviderExternal()` requires
 * `ACCESS_CONTENT_PROVIDERS_EXTERNALLY` (granted to com.android.shell) and does
 * not need a ProcessRecord for the caller. The returned IContentProvider is
 * called directly, so [com.floe.android.rootsystem.ipc.FloeSystemProvider]
 * still observes the real server UID/PID and no provider permission, UID check
 * or launch-token check is relaxed.
 *
 * Shizuku's BinderSender uses the same platform entry point (Apache-2.0, pinned
 * in vendor/embedded-shizuku/UPSTREAM.json); this reflection surface is
 * Floe-authored, fixed to the host authority and never logs payloads.
 */
internal object AppProviderClient {

    /** Stable, non-sensitive failure classes surfaced through ProviderPublisher. */
    const val FAILURE_UNAVAILABLE = "provider_unavailable"
    const val FAILURE_API = "provider_api"
    const val FAILURE_DENIED = "provider_denied"
    const val FAILURE_DEAD = "provider_dead"
    const val FAILURE_REMOTE = "provider_remote"
    const val FAILURE_TRANSPORT = "provider_transport"

    /** Host/user pair used only for the external provider reference. */
    private const val CALLER_TAG = "floe-publish"

    sealed interface Result {
        /** The provider executed call(); [reply] is its exact return value. */
        data class Reply(val reply: Bundle?) : Result

        /** The provider was not reached; [code] is a stable failure class. */
        data class Failed(val code: String) : Result
    }

    fun call(authority: String, userId: Int, method: String, arg: String?, extras: Bundle): Result {
        val activityManager = activityManager() ?: return Result.Failed(FAILURE_UNAVAILABLE)
        val getter = getContentProviderExternalMethod ?: return Result.Failed(FAILURE_API)
        val holder = try {
            if (getter.parameterCount == 4) {
                getter.invoke(activityManager, authority, userId, null, CALLER_TAG)
            } else {
                getter.invoke(activityManager, authority, userId, null)
            }
        } catch (t: Throwable) {
            return Result.Failed(classifyFailure(t))
        } ?: return Result.Failed(FAILURE_TRANSPORT)

        try {
            val provider = providerOf(holder) ?: return Result.Failed(FAILURE_API)
            val call = providerCallMethod ?: return Result.Failed(FAILURE_API)
            val reply = try {
                when {
                    Build.VERSION.SDK_INT >= 31 -> {
                        val source = attributionSource() ?: return Result.Failed(FAILURE_API)
                        call.invoke(provider, source, authority, method, arg, extras)
                    }
                    // Android 11: (callingPkg, featureId, authority, method, arg, extras)
                    call.parameterCount == 6 ->
                        call.invoke(provider, null, null, authority, method, arg, extras)
                    // Android 10: (callingPkg, authority, method, arg, extras)
                    call.parameterCount == 5 ->
                        call.invoke(provider, null, authority, method, arg, extras)
                    // Android 9: (callingPkg, method, arg, extras)
                    else ->
                        call.invoke(provider, null, method, arg, extras)
                }
            } catch (t: Throwable) {
                return Result.Failed(classifyFailure(t))
            }
            return Result.Reply(reply as? Bundle)
        } finally {
            removeContentProviderExternalMethod?.let { remover ->
                runCatching { remover.invoke(activityManager, authority, null) }
            }
        }
    }

    // ------------------------------------------------------- reflection surface

    @Volatile
    private var cachedActivityManager: Any? = null

    private fun activityManager(): Any? {
        cachedActivityManager?.let { return it }
        SystemContext.exemptBootstrapApis()
        val value = runCatching {
            val type = Class.forName("android.app.ActivityManager")
            val getService = runCatching { type.getMethod("getService") }.getOrElse {
                type.getDeclaredMethod("getService").apply { isAccessible = true }
            }
            getService.invoke(null)
        }.getOrNull() ?: return null
        cachedActivityManager = value
        return value
    }

    private fun activityManagerMethods(): List<Method> =
        runCatching { Class.forName("android.app.IActivityManager").methods.toList() }
            .getOrDefault(emptyList())

    private fun contentProviderMethods(): List<Method> =
        runCatching { Class.forName("android.content.IContentProvider").methods.toList() }
            .getOrDefault(emptyList())

    private val getContentProviderExternalMethod: Method? by lazy {
        activityManagerMethods().firstOrNull {
            it.name == "getContentProviderExternal" &&
                externalShapeMatches(Build.VERSION.SDK_INT, it.parameterNames())
        }
    }

    private val removeContentProviderExternalMethod: Method? by lazy {
        activityManagerMethods().firstOrNull {
            it.name == "removeContentProviderExternal" &&
                removeShapeMatches(it.parameterNames())
        }
    }

    private val providerCallMethod: Method? by lazy {
        contentProviderMethods().firstOrNull {
            it.name == "call" && callShapeMatches(Build.VERSION.SDK_INT, it.parameterNames())
        }
    }

    private val providerField: Field? by lazy {
        runCatching {
            Class.forName("android.app.ContentProviderHolder")
                .getField("provider")
                .apply { isAccessible = true }
        }.getOrNull()
    }

    private fun providerOf(holder: Any): Any? = providerField?.let { field ->
        runCatching { field.get(holder) }.getOrNull()
    }

    private fun attributionSource(): Any? = runCatching {
        val builderType = Class.forName("android.content.AttributionSource\$Builder")
        val builder = builderType.getConstructor(Int::class.javaPrimitiveType!!)
            .newInstance(Process.myUid())
        builderType.getMethod("build").invoke(builder)
    }.getOrNull()

    private fun Method.parameterNames(): List<String> = parameterTypes.map { it.name }

    // ------------------------------------------------------------ pure decisions

    /**
     * `IActivityManager.getContentProviderExternal` gained the trailing tag
     * argument in Android 10. Android 9 still has the three-argument form.
     */
    internal fun externalShapeMatches(api: Int, parameterTypeNames: List<String>): Boolean {
        if (parameterTypeNames.size !in 3..4) return false
        if (parameterTypeNames[0] != "java.lang.String") return false
        if (parameterTypeNames[1] != "int") return false
        if (parameterTypeNames[2] != "android.os.IBinder") return false
        return if (parameterTypeNames.size == 3) {
            api <= 28
        } else {
            api >= 29 && parameterTypeNames[3] == "java.lang.String"
        }
    }

    internal fun removeShapeMatches(parameterTypeNames: List<String>): Boolean =
        parameterTypeNames.size == 2 &&
            parameterTypeNames[0] == "java.lang.String" &&
            parameterTypeNames[1] == "android.os.IBinder"

    /**
     * `IContentProvider.call` changed shape by API: 4 arguments on Android 9,
     * authority added on 10, featureId added on 11, AttributionSource replacing
     * the two caller strings on 12+. Only the exact declared shape is accepted.
     */
    internal fun callShapeMatches(api: Int, parameterTypeNames: List<String>): Boolean {
        if (parameterTypeNames.lastOrNull() != "android.os.Bundle") return false
        return when {
            api >= 31 -> parameterTypeNames.size == 5 &&
                parameterTypeNames[0] == "android.content.AttributionSource" &&
                parameterTypeNames.subList(1, 4).all { it == "java.lang.String" }
            api == 30 -> parameterTypeNames.size == 6 &&
                parameterTypeNames.take(5).all { it == "java.lang.String" }
            api == 29 -> parameterTypeNames.size == 5 &&
                parameterTypeNames.take(4).all { it == "java.lang.String" }
            else -> parameterTypeNames.size == 4 &&
                parameterTypeNames.take(3).all { it == "java.lang.String" }
        }
    }

    /** Stable class code only; exception messages and payloads are never used. */
    internal fun classifyFailure(throwable: Throwable): String {
        var cause = throwable
        var depth = 0
        while (cause is InvocationTargetException && depth < 4) {
            cause = cause.targetException ?: break
            depth++
        }
        return when (cause) {
            is SecurityException -> FAILURE_DENIED
            is android.os.DeadObjectException -> FAILURE_DEAD
            is android.os.RemoteException -> FAILURE_REMOTE
            else -> FAILURE_TRANSPORT
        }
    }
}
