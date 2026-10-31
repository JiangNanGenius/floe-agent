// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

/**
 * Post-install settlement rules.
 *
 * [ApkValidationPolicy] deliberately requires a STRICTLY higher versionCode
 * when admitting a NEW install. That admission rule must not be applied a
 * second time to the download that a completed install already consumed: once
 * the update lands, the verified target's versionCode equals the installed
 * one, and re-admitting it reports VERSION_NOT_HIGHER (surfaced as
 * [DownloadFailure.APK_IDENTITY]). The result is a false "package does not
 * match this app or device" state after the user already saw a successful
 * install.
 *
 * Settlement retires only the exact task-owned target:
 *  * the installed app must be the same package and signer set and at least
 *    the recorded versionCode (an ordinary successful update, or a newer
 *    install that already superseded it);
 *  * the completed download must be the exact file/version/SHA that was
 *    streamed into that install session;
 *  * a staged archive counts as the installed artifact only when package,
 *    versionCode, versionName (when reported) and signer set all match the
 *    installed app. The caller must still verify the archive's release
 *    SHA-256 first; this rule never replaces checksum/signature validation.
 *
 * A stale or genuinely different target fails these checks and remains
 * subject to the normal admission rejection.
 */
internal object UpdateSettlementPolicy {

    /** The persisted install record and the installed app are the same install. */
    fun installedMatchesRecord(installed: ApkIdentity, record: PendingInstall): Boolean {
        if (record.packageName.isNotEmpty() && installed.packageName != record.packageName) return false
        if (record.signerSha256.isNotEmpty() && installed.signerSha256 != record.signerSha256) return false
        return installed.longVersionCode >= record.versionCode
    }

    /** This completed download is exactly the artifact the install record consumed. */
    fun isConsumedDownload(meta: DownloadMeta, record: PendingInstall): Boolean =
        meta.completed &&
            meta.fileName == record.fileName &&
            meta.versionName == record.versionName &&
            meta.expectedSha256.equals(record.sha256, ignoreCase = true)

    /** The archive identity is exactly the app that is already installed. */
    fun isInstalledArtifact(candidate: ApkIdentity, installed: ApkIdentity): Boolean {
        if (candidate.packageName != installed.packageName) return false
        if (candidate.longVersionCode != installed.longVersionCode) return false
        if (candidate.signerSha256.isEmpty() || installed.signerSha256.isEmpty()) return false
        if (candidate.signerSha256 != installed.signerSha256) return false
        if (candidate.versionName.isNotEmpty() && installed.versionName.isNotEmpty() &&
            candidate.versionName != installed.versionName
        ) {
            return false
        }
        return true
    }
}
