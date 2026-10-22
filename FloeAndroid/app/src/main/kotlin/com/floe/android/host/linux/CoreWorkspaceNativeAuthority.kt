// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.bridge.LinuxWorkspaceNative
import com.floe.android.workspacebridge.WorkspaceNativeAuthority
import com.floe.android.workspacebridge.WorkspaceBridgeException

/** Core-only adapter. The captured call identity comes from the original native context. */
internal class CoreWorkspaceNativeAuthority : WorkspaceNativeAuthority {
    override fun binding(rootEpoch: Long, runID: String, grantID: String): ByteArray? =
        LinuxWorkspaceNative.binding(rootEpoch, runID, grantID)
    override fun bindingForCall(rootEpoch: Long, runID: String, toolCallID: String?, grantID: String): ByteArray? =
        if (toolCallID == null) LinuxWorkspaceNative.binding(rootEpoch, runID, grantID)
        else LinuxWorkspaceNative.bindingForCall(rootEpoch, runID, toolCallID, grantID)

    private fun known(value: ByteArray?): ByteArray = value ?: throw WorkspaceBridgeException("nativeReplyUnknown")
    override fun openSession(bindingJson: ByteArray): ByteArray = known(LinuxWorkspaceNative.openSession(bindingJson))
    override fun baselineBegin(sessionKey: String): ByteArray = known(LinuxWorkspaceNative.baselineBegin(sessionKey))
    override fun baselineHeader(sessionKey: String, index: Long): ByteArray = known(LinuxWorkspaceNative.baselineHeader(sessionKey, index))
    override fun baselineFinish(sessionKey: String, appliedCount: Long, appliedBytes: Long): ByteArray = known(LinuxWorkspaceNative.baselineFinish(sessionKey, appliedCount, appliedBytes))
    override fun exportBegin(sessionKey: String): ByteArray = known(LinuxWorkspaceNative.exportBegin(sessionKey))
    override fun exportStage(sessionKey: String, headerJson: ByteArray, dataFd: Int): ByteArray = known(LinuxWorkspaceNative.exportStage(sessionKey, headerJson, dataFd))
    override fun exportFinish(sessionKey: String): ByteArray = known(LinuxWorkspaceNative.exportFinish(sessionKey))
    override fun abort(sessionKey: String, reason: String): ByteArray = known(LinuxWorkspaceNative.abort(sessionKey, reason))
    override fun stats(): ByteArray = known(LinuxWorkspaceNative.stats())
    override fun sweep(nowSeconds: Long, graceSeconds: Long): ByteArray = known(LinuxWorkspaceNative.sweep(nowSeconds, graceSeconds))
    override fun baselineOpenData(sessionKey: String, index: Long): Int = LinuxWorkspaceNative.baselineOpenData(sessionKey, index)
    override fun closeSession(sessionKey: String): Int = LinuxWorkspaceNative.closeSession(sessionKey)
}
