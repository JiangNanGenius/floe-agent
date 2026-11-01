// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Process

/**
 * Full-only publication provider for the Floe-owned embedded service.
 *
 * It is exported only because the shell/root service runs outside the App UID;
 * callers still need `android.permission.INTERACT_ACROSS_USERS_FULL`, and the
 * hub additionally checks the exact UID for the advertised mode, the launch
 * token (when one is expected) and the binder metadata. It is not a general
 * binder relay and returns no binder to any caller except the App's own UID.
 */
class FloeSystemProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle? {
        val callerUid = Binder.getCallingUid()
        val callerPid = Binder.getCallingPid()
        return when (method) {
            METHOD_SEND_BINDER -> publish(callerUid, callerPid, extras)
            METHOD_GET_BINDER -> getBinder(callerUid, extras)
            else -> null
        }
    }

    private fun publish(callerUid: Int, callerPid: Int, extras: Bundle?): Bundle? {
        return when (val result = BinderHub.accept(callerUid, callerPid, extras)) {
            is BinderHub.AcceptResult.Ok -> Bundle().apply {
                putBinder(BinderProtocol.KEY_CLIENT, BinderHub.AppHandle())
            }
            is BinderHub.AcceptResult.Rejected -> null
        }
    }

    private fun getBinder(callerUid: Int, extras: Bundle?): Bundle? {
        if (callerUid != Process.myUid()) return null
        val mode = extras?.getString(BinderProtocol.KEY_SERVER_MODE) ?: return null
        val published = BinderHub.peek(mode) ?: return null
        return Bundle().apply { putBinder(BinderProtocol.KEY_BINDER, published.binder) }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        const val AUTHORITY_SUFFIX = ".floe.system"
        const val METHOD_SEND_BINDER = "sendBinder"
        const val METHOD_GET_BINDER = "getBinder"
    }
}
