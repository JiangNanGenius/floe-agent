// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.ipc;

import android.os.Bundle;

/**
 * Floe-only typed privileged service interface. This descriptor/name is never
 * shared with an external Shizuku manager or any third-party app. Every method
 * validates the caller UID/package/signature, a live task/run/epoch/grant and
 * the requested closed operation before touching the device.
 *
 * All request Bundles use the closed key set documented in BinderProtocol.
 * Unknown keys are ignored but no raw command/script/path escape hatch exists.
 */
interface IFloeSystemService {
    int protocolVersion();
    boolean ping();
    Bundle describe();

    Bundle registerGrant(in Bundle grant);
    void revokeGrant(String grantId);
    void revokeAllGrants();

    Bundle fileList(in Bundle request);
    Bundle fileRead(in Bundle request);
    Bundle fileWrite(in Bundle request, in byte[] data);
    Bundle fileMove(in Bundle request);
    Bundle fileDelete(in Bundle request);

    Bundle processQuery(in Bundle request);
    Bundle serviceQuery(in Bundle request);
    Bundle packageQuery(in Bundle request);
    Bundle networkDiagnostics(in Bundle request);
    Bundle managePackage(in Bundle request);
    Bundle packetCapture(in Bundle request);

    void cancel(String requestId);
    void stopOwnedService(in Bundle request);

    // ------------------------------------------------------------------
    // Wire 3 additions. NEVER insert before this point: every method above
    // keeps its exact wire-2 position so a verified older-protocol service
    // can still be typed-stopped across a same-versionCode upgrade. These
    // methods have never shipped publicly; they are appended after the
    // legacy stopOwnedService transaction.
    // ------------------------------------------------------------------
    Bundle installPackage(in Bundle request);
    Bundle uninstallPackage(in Bundle request);
    Bundle stageApk(in Bundle request);

    // ------------------------------------------------------------------
    // App-state additions, appended after the wire-3 block (same unshipped
    // protocol revision). Selected app enabled-state and per-user preinstalled
    // lifecycle with real post-pm read-back.
    // ------------------------------------------------------------------
    Bundle setPackageEnabled(in Bundle request);
    Bundle removePackageForUser(in Bundle request);
    Bundle restorePackage(in Bundle request);

    /**
     * Typed authenticated maintenance: release one owned staged APK by its
     * content digest for the App's staged-list removal. Not a task operation;
     * no package-manager effect.
     */
    Bundle releaseStagedApk(in Bundle request);
}
