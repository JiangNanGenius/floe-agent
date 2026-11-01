// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import kotlinx.coroutines.flow.StateFlow

/**
 * Public, host-facing API for the Full-only embedded system access module.
 *
 * This module is deliberately NOT a general Shizuku client and NOT a generic
 * shell. It owns one Floe-only privileged service identity, one optional root
 * backend, typed operations only, and live task/run/epoch/grant checking before
 * every host operation. The App host supplies the actual authority callback and
 * the approved credential store; this module never creates grants by itself.
 */

/**
 * At most one backend is the active owner: [AdbStatus.ServiceAlive] and
 * [RootStatus.Enabled] are mutually exclusive. While Root owns the transport,
 * an otherwise live ADB process is reported as [AdbStatus.Paired] standby.
 */
data class RootSystemSnapshot(
    val adb: AdbStatus,
    val root: RootStatus,
    val pairingSupported: Boolean,
    val pairingCodeRequired: Boolean,
)

sealed interface AdbStatus {
    /** User explicitly disabled embedded ADB, or this build has no usable key. */
    data object Disabled : AdbStatus

    /** No pairing trust exists yet; a user-initiated local pairing is required. */
    data object PairRequired : AdbStatus

    /** Pairing handshake in progress. The 6-digit code lives in RAM only. */
    data object Pairing : AdbStatus

    /** Pairing trust exists but no live Floe service binder is attached. */
    data class Paired(val connectPort: Int? = null) : AdbStatus

    /**
     * This binder is the current active service transport and its actual
     * process UID was verified. A paired/standby ADB process while Root owns
     * the transport is reported as [Paired], never as this state.
     */
    data class ServiceAlive(val effectiveUid: Int, val mode: String = "adb") : AdbStatus

    /** Binder died after being alive. Pending host work is fenced. */
    data class ServiceDied(val code: String? = null) : AdbStatus

    /** App version/signing changed or device restarted; user must start again. */
    data object RestartRequired : AdbStatus

    /** Grant was revoked; in-flight calls are cancelled and later calls refused. */
    data object Revoked : AdbStatus

    data class Error(val message: String, val code: String? = null) : AdbStatus
}

sealed interface RootStatus {
    /** Default: root backend is off even if a superuser manager is present. */
    data object Off : RootStatus

    /** User explicitly enabled root, but no live existing root grant was found. */
    data object GrantNotFound : RootStatus

    /**
     * The existing root grant is available, but Root is not the active owner
     * (default-off, Root service death, or ADB is the active owner).
     */
    data object GrantFound : RootStatus

    /** Root is the current active owner and verified effective UID 0 itself. */
    data class Enabled(val effectiveUid: Int = 0) : RootStatus

    /** Root was requested but the actual grant/UID check failed. */
    data class Refused(val code: String) : RootStatus

    data class Error(val message: String, val code: String? = null) : RootStatus
}

/** Closed operation set understood by the privileged service. */
enum class SystemOperation {
    FILE_LIST,
    FILE_READ,
    FILE_WRITE,
    FILE_MOVE,
    FILE_DELETE,
    PROCESS_QUERY,
    SERVICE_QUERY,
    PACKAGE_QUERY,
    NETWORK_DIAGNOSTICS,
    PACKAGE_FORCE_STOP,
}

/**
 * Fencing identity copied from the real ToolContext by the App host
 * (conversation/task/run/epoch plus the existing approval grant and call IDs).
 * An opaque ID alone never authorizes an operation; the server matches these
 * values against a live grant registered through [RootSystemController.registerGrant].
 */
data class OperationClaim(
    val taskId: String,
    val runId: String,
    val epoch: Long,
    val grantId: String,
    val requestId: String,
    val callId: String? = null,
) {
    fun isWellFormed(): Boolean =
        taskId.isNotBlank() && runId.isNotBlank() && epoch > 0 &&
            grantId.isNotBlank() && requestId.isNotBlank() &&
            taskId.length <= 128 && runId.length <= 128 &&
            grantId.length <= 128 && requestId.length <= 128 &&
            (callId == null || callId.length <= 128)
}

/** One host-approved scope root. `scopeId` is opaque to the service. */
data class ScopeRoot(
    val scopeId: String,
    val path: String,
    val writable: Boolean,
)

/**
 * A grant registered by the App host after its ordinary admission/approval
 * flow. This is a projection of live host authority, not a new permission DB.
 * Expiry is mandatory; the server rejects an expired or revoked grant.
 */
data class GrantRequest(
    val grantId: String,
    val taskId: String,
    val runId: String,
    val epoch: Long,
    val expiresAtMillis: Long,
    val scopes: List<ScopeRoot>,
    val operations: Set<SystemOperation>,
    val packageManagementAllowed: Boolean,
) {
    fun isWellFormed(): Boolean =
        grantId.isNotBlank() && taskId.isNotBlank() && runId.isNotBlank() &&
            epoch > 0 && expiresAtMillis > 0 &&
            grantId.length <= 128 && taskId.length <= 128 && runId.length <= 128 &&
            scopes.size in 1..8 &&
            operations.isNotEmpty() &&
            scopes.all { it.scopeId.isNotBlank() && it.scopeId.length <= 64 && it.path.startsWith("/") }
}

data class GrantReceipt(val grantId: String, val registeredAtMillis: Long, val expiresAtMillis: Long)

/**
 * Live host authority callback. Implementations must be backed by the existing
 * task lifecycle/permission services, never by a model-supplied argument or a
 * parallel grant database.
 */
interface RootSystemAuthority {
    /** Last check immediately before a host operation is dispatched. */
    fun authorize(request: RootOperationRequest): AuthorityDecision

    /** True when the owning task/run was stopped, taken over or revoked. */
    fun isCancelled(request: RootOperationRequest): Boolean
}

data class RootOperationRequest(
    val claim: OperationClaim,
    val operation: SystemOperation,
    val target: String?,
    val destructive: Boolean,
)

sealed interface AuthorityDecision {
    data object Allowed : AuthorityDecision
    data class Denied(val code: String, val message: String? = null) : AuthorityDecision
}

/** Closed result shape returned to the App host and Agent tool layer. */
sealed interface RootResult<out T> {
    data class Ok<T>(val value: T) : RootResult<T>
    data class Denied(val code: String, val message: String? = null) : RootResult<Nothing>
    data class Unavailable(val code: String) : RootResult<Nothing>
    data class Failed(val code: String, val message: String? = null) : RootResult<Nothing>
}

data class FileEntry(
    val name: String,
    val relativePath: String,
    val directory: Boolean,
    val sizeBytes: Long,
    val modifiedAtMillis: Long,
)

data class FileRead(
    val bytes: ByteArray,
    val truncated: Boolean,
)

data class FileWriteReceipt(
    val relativePath: String,
    val bytesWritten: Int,
    val atomic: Boolean,
)

data class MoveReceipt(val from: String, val to: String)

data class DeleteReceipt(val deleted: Int)

data class ProcessRecord(
    val pid: Int,
    val uid: Int,
    val name: String,
)

data class ServiceRecord(
    val processName: String,
    val className: String,
    val pid: Int,
    val foreground: Boolean,
)

data class PackageRecord(
    val packageName: String,
    val uid: Int,
    val versionCode: Long,
    val system: Boolean,
    val enabled: Boolean,
    val running: Boolean,
)

data class PackageQuery(val packages: List<PackageRecord>, val truncated: Boolean)

data class PackageManagementReceipt(
    val packageName: String,
    val userId: Int,
    val operation: String,
    val stillRunning: Boolean,
)

/** Android 9/10 PC USB bootstrap material. Display/copy only; never execute. */
data class UsbBootstrap(
    val adbShellCommand: String,
    val script: String,
)

data class InterfaceInfo(
    val name: String,
    val up: Boolean,
    val addresses: List<String>,
)

data class RouteInfo(
    val interfaceName: String,
    val destination: String,
    val gateway: String?,
    val defaultRoute: Boolean,
)

data class NetworkDiagnostics(
    val interfaces: List<InterfaceInfo>,
    val routes: List<RouteInfo>,
    val activeTransports: List<String>,
)

/** Result of a pairing/start/stop/probe lifecycle action. */
sealed interface AccessActionResult {
    data object Ok : AccessActionResult
    data class Denied(val code: String) : AccessActionResult
    data class Unavailable(val code: String) : AccessActionResult
    data class Failed(val code: String, val message: String? = null) : AccessActionResult
}

sealed interface PairingResult {
    data object Success : PairingResult
    data object InvalidCode : PairingResult
    data class Unsupported(val code: String) : PairingResult
    data object Timeout : PairingResult
    data class Failed(val code: String) : PairingResult
}

/**
 * Host-supplied configuration. `allowedScopeBases` is the explicit user-granted
 * ceiling enforced by the controller; an empty or fully invalid list never
 * means the whole filesystem. The privileged service independently re-applies
 * the intrinsic path policy (shared storage, other-app data, read-only platform
 * trees, and Floe/kernel/credential denials) on every canonical target.
 * `signingSha256` binds the service to the same Floe signing identity; it is
 * computed from the installed package by [RootSystemConfig.fromContext].
 */
data class RootSystemConfig(
    val packageName: String,
    val serverClass: String,
    val nativeLibraryDir: String,
    val apkPath: String,
    val appVersionCode: Long,
    val signingSha256: String,
    val allowedScopeBases: List<String>,
    val connectPort: Int? = null,
    val allowPackageManagement: Boolean = false,
    val maxFileReadBytes: Int = 1024 * 1024,
    val maxFileWriteBytes: Int = 8 * 1024 * 1024,
    val maxListEntries: Int = 200,
    val pairingTimeoutMillis: Int = 15_000,
) {
    companion object {
        const val DEFAULT_SERVER_CLASS = "com.floe.android.rootsystem.server.FloeSystemServer"

        /**
         * Builds the host configuration from the installed Floe package. The
         * signing digest is read from the actual package, not a model or caller
         * argument. `allowedScopeBases` remains an explicit host policy input.
         */
        fun fromContext(
            context: android.content.Context,
            allowedScopeBases: List<String>,
            connectPort: Int? = null,
            allowPackageManagement: Boolean = false,
        ): RootSystemConfig {
            val app = context.applicationContext ?: context
            val info = app.packageManager.getPackageInfo(
                app.packageName,
                android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES,
            )
            val signers = info.signingInfo?.apkContentsSigners
                ?: error("floe package has no signing identity")
            require(signers.isNotEmpty()) { "floe package has no signing identity" }
            val certificates = signers.map {
                java.security.cert.CertificateFactory.getInstance("X.509")
                    .generateCertificate(it.toByteArray().inputStream()) as java.security.cert.X509Certificate
            }.toTypedArray()
            val hash = com.floe.android.rootsystem.policy.SigningDigest.of(certificates)
            return RootSystemConfig(
                packageName = app.packageName,
                serverClass = DEFAULT_SERVER_CLASS,
                nativeLibraryDir = app.applicationInfo.nativeLibraryDir,
                apkPath = app.applicationInfo.sourceDir,
                appVersionCode = info.longVersionCode,
                signingSha256 = hash,
                allowedScopeBases = allowedScopeBases,
                connectPort = connectPort,
                allowPackageManagement = allowPackageManagement,
            )
        }
    }
}

/** The App host constructs exactly one controller and owns its lifetime. */
class RootSystemController internal constructor(
    internal val config: RootSystemConfig,
    internal val authority: RootSystemAuthority,
) : java.io.Closeable {

    internal lateinit var impl: RootSystemControllerImpl
    private val closed = java.util.concurrent.atomic.AtomicBoolean(false)

    val adbStatus: StateFlow<AdbStatus> get() = impl.adbStatus
    val rootStatus: StateFlow<RootStatus> get() = impl.rootStatus
    val pairingSupported: Boolean get() = impl.pairingSupported

    fun snapshot(): RootSystemSnapshot = impl.snapshot()

    suspend fun refresh() = impl.refresh()

    suspend fun pair(pairingPort: Int, pairingCode: CharArray): PairingResult =
        impl.pair(pairingPort, pairingCode)

    suspend fun cancelPairing() = impl.cancelPairing()

    suspend fun forgetPairing() = impl.forgetPairing()

    /**
     * Android 9/10 PC USB bootstrap: returns the exact `adb shell` command to
     * run from the user's computer. This does not start anything by itself and
     * is not a model-callable host command; the App presents it to the user.
     */
    suspend fun usbBootstrap(connectPort: Int? = null): RootResult<UsbBootstrap> =
        impl.usbBootstrap(connectPort)

    suspend fun startAdbService(connectPort: Int? = null): AccessActionResult =
        impl.startAdbService(connectPort)

    suspend fun stopAdbService(): AccessActionResult = impl.stopAdbService()

    suspend fun rebind(): AccessActionResult = impl.rebind()

    suspend fun probe(): AccessActionResult = impl.probe()

    suspend fun setRootEnabled(enabled: Boolean): AccessActionResult = impl.setRootEnabled(enabled)

    suspend fun registerGrant(request: GrantRequest): RootResult<GrantReceipt> =
        impl.registerGrant(request)

    suspend fun revokeGrant(grantId: String): AccessActionResult = impl.revokeGrant(grantId)

    suspend fun revokeAllGrants(): AccessActionResult = impl.revokeAllGrants()

    suspend fun fileList(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        maxEntries: Int = config.maxListEntries,
    ): RootResult<List<FileEntry>> = impl.fileList(claim, scopeId, relativePath, maxEntries)

    suspend fun fileRead(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        offset: Long = 0,
        maxBytes: Int = 64 * 1024,
    ): RootResult<FileRead> = impl.fileRead(claim, scopeId, relativePath, offset, maxBytes)

    suspend fun fileWrite(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        data: ByteArray,
        overwrite: Boolean = false,
    ): RootResult<FileWriteReceipt> = impl.fileWrite(claim, scopeId, relativePath, data, overwrite)

    suspend fun fileMove(
        claim: OperationClaim,
        scopeId: String,
        fromRelativePath: String,
        toRelativePath: String,
        overwrite: Boolean = false,
    ): RootResult<MoveReceipt> =
        impl.fileMove(claim, scopeId, fromRelativePath, toRelativePath, overwrite)

    suspend fun fileDelete(
        claim: OperationClaim,
        scopeId: String,
        relativePath: String,
        recursive: Boolean = false,
    ): RootResult<DeleteReceipt> = impl.fileDelete(claim, scopeId, relativePath, recursive)

    suspend fun processQuery(
        claim: OperationClaim,
        filter: String? = null,
        maxEntries: Int = 200,
    ): RootResult<List<ProcessRecord>> = impl.processQuery(claim, filter, maxEntries)

    suspend fun serviceQuery(
        claim: OperationClaim,
        maxEntries: Int = 200,
    ): RootResult<List<ServiceRecord>> = impl.serviceQuery(claim, maxEntries)

    suspend fun packageQuery(
        claim: OperationClaim,
        packageName: String? = null,
        includeSystem: Boolean = true,
        maxEntries: Int = 200,
    ): RootResult<PackageQuery> = impl.packageQuery(claim, packageName, includeSystem, maxEntries)

    suspend fun networkDiagnostics(claim: OperationClaim): RootResult<NetworkDiagnostics> =
        impl.networkDiagnostics(claim)

    suspend fun forceStopPackage(
        claim: OperationClaim,
        packageName: String,
        userId: Int = 0,
    ): RootResult<PackageManagementReceipt> = impl.forceStopPackage(claim, packageName, userId)

    suspend fun cancelOperation(claim: OperationClaim): AccessActionResult =
        impl.cancelOperation(claim)

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            impl.close()
            RootSystemModule.runtime.detach(this)
        }
    }
}

/**
 * Full-only module facade used by DistributionModules and App settings. It
 * reports actual service state, never unconditional AVAILABLE.
 */
object RootSystemModule : com.floe.android.contracts.CapabilitySource {
    internal val runtime: RootSystemRuntime = RootSystemRuntime()
    val adbStatus: StateFlow<AdbStatus> get() = runtime.adbStatus
    val rootStatus: StateFlow<RootStatus> get() = runtime.rootStatus

    fun snapshot(): RootSystemSnapshot = runtime.snapshot()

    fun createController(
        config: RootSystemConfig,
        credentials: com.floe.android.contracts.CredentialStore,
        authority: RootSystemAuthority,
        context: android.content.Context,
    ): RootSystemController {
        val controller = RootSystemController(config, authority)
        controller.impl = RootSystemControllerImpl(
            context.applicationContext ?: context,
            config,
            credentials,
            authority,
            runtime,
        )
        runtime.attach(controller)
        return controller
    }

    override fun capabilities(): List<com.floe.android.contracts.Capability> {
        val snapshot = runtime.snapshot()
        val system = when (snapshot.adb) {
            is AdbStatus.ServiceAlive -> com.floe.android.contracts.Availability.AVAILABLE
            is AdbStatus.Paired -> com.floe.android.contracts.Availability.NEEDS_CONFIGURATION
            is AdbStatus.RestartRequired -> com.floe.android.contracts.Availability.NEEDS_CONFIGURATION
            is AdbStatus.PairRequired -> com.floe.android.contracts.Availability.NEEDS_PERMISSION
            is AdbStatus.Pairing -> com.floe.android.contracts.Availability.NEEDS_CONFIGURATION
            is AdbStatus.Disabled -> com.floe.android.contracts.Availability.UNSUPPORTED
            is AdbStatus.Revoked -> com.floe.android.contracts.Availability.NEEDS_PERMISSION
            is AdbStatus.ServiceDied -> com.floe.android.contracts.Availability.NEEDS_CONFIGURATION
            is AdbStatus.Error -> com.floe.android.contracts.Availability.NEEDS_CONFIGURATION
        }
        val root = when (snapshot.root) {
            is RootStatus.Enabled -> com.floe.android.contracts.Availability.AVAILABLE
            is RootStatus.GrantFound -> com.floe.android.contracts.Availability.NEEDS_CONFIGURATION
            is RootStatus.GrantNotFound -> com.floe.android.contracts.Availability.NEEDS_PERMISSION
            is RootStatus.Off -> com.floe.android.contracts.Availability.NEEDS_PERMISSION
            is RootStatus.Refused -> com.floe.android.contracts.Availability.NEEDS_PERMISSION
            is RootStatus.Error -> com.floe.android.contracts.Availability.UNSUPPORTED
        }
        val systemBackend = when {
            system == com.floe.android.contracts.Availability.AVAILABLE -> system
            root == com.floe.android.contracts.Availability.AVAILABLE -> root
            system == com.floe.android.contracts.Availability.NEEDS_CONFIGURATION -> system
            root == com.floe.android.contracts.Availability.NEEDS_CONFIGURATION -> root
            system == com.floe.android.contracts.Availability.NEEDS_PERMISSION -> system
            else -> root
        }
        return listOf(
            com.floe.android.contracts.Capability("system.adb", system),
            com.floe.android.contracts.Capability("system.root", root),
            com.floe.android.contracts.Capability("system.files", systemBackend),
            com.floe.android.contracts.Capability("system.packages", systemBackend),
            com.floe.android.contracts.Capability("system.diagnostics", systemBackend),
        )
    }
}
