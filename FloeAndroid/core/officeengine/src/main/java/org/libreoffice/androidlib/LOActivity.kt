/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This Source Code Form is derived from the Collabora Online / LibreOffice
 * android lib (upstream LOActivity.java) and is subject to the terms of the
 * Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed
 * with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Floe G05-R1 compatibility host (the deliberate design decision from Main's
 * preflight, now confirmed from release-source code):
 *
 * The prebuilt libandroidapp.so binds to Java ONLY through
 *   1. the exported static-JNI symbols Java_org_libreoffice_androidlib_LOActivity_*
 *      (so the declaring class MUST keep this exact package/name and the seven
 *      native methods below), plus
 *      Java_org_libreoffice_androidlib_COWebViewClient_getEmbeddedMediaPath;
 *   2. callbacks resolved with GetObjectClass(instance) + GetMethodID of
 *      rawCallFakeWebsocketOnMessage([B)V and postMobileMessage(Ljava/lang/String;)V
 *      on whatever object is passed to createCOOLWSD (androidapp.cpp lines
 *      111/125/253); and
 *   3. FindClass of org/libreoffice/androidlib/lok/LokClipboardEntry and
 *      org/libreoffice/androidlib/lok/LokClipboardData with their field names.
 * Nothing in native code requires android.app.Activity itself, so this host
 * class replaces the 1969-line upstream LOActivity (AllFilesAccess, external
 * app flows, storage permissions, print, recents - none of which Floe authorises
 * here) while preserving the exact ABI. The instance passed to createCOOLWSD is
 * held by native code as a process-wide global ref until the next create; the
 * owning session fences all callbacks by generation through [EngineBridge].
 */
package org.libreoffice.androidlib

import android.content.res.AssetManager
import android.util.Log
import android.webkit.JavascriptInterface
import org.libreoffice.androidlib.lok.LokClipboardData

/**
 * JNI callback/transport boundary. One implementation exists per live engine
 * session; it MUST be generation-fenced and MUST NOT throw, because the
 * native side calls these methods from engine threads with a raw JNIEnv
 * (androidapp.cpp send2JS/postDirectMessage only ExceptionDescribe()).
 */
interface EngineBridge {
    /** beforeMessageFromWebView equivalent: true forwards the raw message to native. */
    fun onMessageFromJs(message: String): Boolean

    /** afterMessageFromWebView equivalent (copy/cut clipboard population). */
    fun onMessageForwarded(message: String)

    /** One complete ProxySocket-protocol message arriving from the engine. */
    fun onMessageToJs(message: ByteArray)

    fun onJsError(message: String)

    fun onJsDebug(message: String)

    fun hasHardwareKeyboard(): Boolean

    fun isChromeOS(): Boolean
}

class LOActivity(private val bridge: EngineBridge) {

    companion object {
        private const val TAG = "FloeLOActivity"

        const val NATIVE_NOT_ATTEMPTED = 0
        const val NATIVE_LOADED = 1
        const val NATIVE_FAILED = 2

        @Volatile
        private var loadState = NATIVE_NOT_ATTEMPTED

        @Volatile
        private var loadError: String? = null

        /**
         * Load libandroidapp.so (its DT_NEEDED chain pulls liblo-native-code.so
         * and the application's own libc++_shared.so). Idempotent and never
         * fatal: a load failure is recorded and surfaced through
         * [nativeLoadState]/[nativeLoadError]; the session then fails actionably
         * instead of crashing or pretending to be ready.
         */
        @JvmStatic
        @Synchronized
        fun ensureNativeLoaded(): Boolean {
            if (loadState == NATIVE_LOADED) return true
            if (loadState == NATIVE_FAILED) return false
            try {
                System.loadLibrary("androidapp")
                loadState = NATIVE_LOADED
                return true
            } catch (e: Throwable) {
                loadError = e.javaClass.simpleName + ": " + e.message
                loadState = NATIVE_FAILED
                Log.e(TAG, "native engine load failed", e)
                return false
            }
        }

        /** NATIVE_* constant, process-wide, for honest availability reporting. */
        @JvmStatic
        fun nativeLoadState(): Int = loadState

        @JvmStatic
        fun nativeLoadError(): String? = loadError
    }

    // ------------------------------------------------------------------
    // Fixed JNI ABI (names + descriptors byte-verified against
    // androidapp.cpp:245/145/302/321/355/441/487)
    // ------------------------------------------------------------------

    /**
     * Initialises/rotates the engine for 'loadFileURL'. The native side keeps
     * a GLOBAL ref to this instance until the next create; the owning session
     * MUST serialize calls (one active document per native lifetime).
     */
    external fun createCOOLWSD(
        dataDir: String,
        cacheDir: String,
        apkFile: String,
        assetManager: AssetManager,
        loadFileURL: String,
        uiMode: String,
        userName: String,
    )

    external fun postMobileMessageNative(message: String)

    external fun saveAs(fileUri: String, format: String, options: String?)

    external fun postUnoCommand(command: String, arguments: String?, bNotifyWhenFinished: Boolean)

    external fun getClipboardContent(aData: LokClipboardData): Boolean

    external fun setClipboardContent(aData: LokClipboardData)

    external fun paste(mimeType: String, data: ByteArray)

    // ------------------------------------------------------------------
    // Java-side entry points reached from the page (addJavascriptInterface
    // "COOLMessageHandler") and from native (postDirectMessage / send2JS)
    // ------------------------------------------------------------------

    /**
     * Called by JS via COOLMessageHandler.postMobileMessage and by native
     * postDirectMessage(). androidapp.cpp:125 GetMethodID(name=postMobileMessage,
     * (Ljava/lang/String;)V). Never throws: an exception left pending on the
     * native callback thread would break every subsequent JNI call.
     */
    @JavascriptInterface
    fun postMobileMessage(message: String) {
        try {
            if (bridge.onMessageFromJs(message)) {
                postMobileMessageNative(message)
                bridge.onMessageForwarded(message)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "postMobileMessage routing failed", t)
            bridge.onJsError("message-routing-failed")
        }
    }

    @JavascriptInterface
    fun postMobileError(message: String) {
        try {
            bridge.onJsError(message)
        } catch (t: Throwable) {
            Log.e(TAG, "postMobileError handler failed", t)
        }
    }

    @JavascriptInterface
    fun postMobileDebug(message: String) {
        try {
            bridge.onJsDebug(message)
        } catch (t: Throwable) {
            Log.e(TAG, "postMobileDebug handler failed", t)
        }
    }

    @JavascriptInterface
    fun isChromeOS(): Boolean {
        return try {
            bridge.isChromeOS()
        } catch (t: Throwable) {
            false
        }
    }

    @JavascriptInterface
    fun hasHardwareKeyboard(): Boolean {
        return try {
            bridge.hasHardwareKeyboard()
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * androidapp.cpp:111 GetMethodID(name=rawCallFakeWebsocketOnMessage, ([B)V).
     * Invoked on engine threads. Never lets an exception reach the JNIEnv.
     */
    fun rawCallFakeWebsocketOnMessage(message: ByteArray) {
        try {
            bridge.onMessageToJs(message)
        } catch (t: Throwable) {
            Log.e(TAG, "rawCallFakeWebsocketOnMessage failed", t)
            bridge.onJsError("websocket-callback-failed")
        }
    }

    /** Java-originated message to the page (mobile: ... events). */
    fun sendToJs(message: String) {
        rawCallFakeWebsocketOnMessage(message.toByteArray(Charsets.UTF_8))
    }
}
