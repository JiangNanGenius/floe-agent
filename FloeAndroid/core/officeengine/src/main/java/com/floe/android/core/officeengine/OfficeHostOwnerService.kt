package com.floe.android.core.officeengine

import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.IBinder

/**
 * Main-process host owner anchor for the R1 Office viewer.
 *
 * The viewer runs in the dedicated `:floe_office` process, so while it is
 * foreground the App (default) process is only cached/background and the
 * cached freezer suspends it. The viewer's exact user close must be
 * acknowledged by the App-side controller BEFORE the native BYE ends the
 * viewer process, and a frozen parent cannot answer that transaction.
 *
 * This service carries no commands, storage, network or permission surface:
 * [onBind] returns an inert [Binder]. It exists only so the foreground
 * viewer Activity can bind to it with `BIND_AUTO_CREATE |
 * BIND_ADJUST_WITH_ACTIVITY`, which makes the system hold this (default app)
 * process at the binding Activity's importance while Office is visible — a
 * real bound process-dependency, not an identity check. Ordinary background
 * limits still apply, and process death releases the connection.
 *
 * Deliberately no `android:process` in the manifest: the default process is
 * the App's main process, which owns the preview controller and the close
 * capability, so the binding keeps the real owner available for foreground
 * Office (including future edit/save rounds). Never exported: the manifest
 * flag enforces the same-UID app boundary, so no caller check is needed here
 * (framework delivers the system binding context).
 */
class OfficeHostOwnerService : Service() {

    private val ownerBinder = Binder()

    override fun onBind(intent: Intent?): IBinder = ownerBinder
}
