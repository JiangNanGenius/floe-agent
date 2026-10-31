// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.os.Binder
import android.os.Bundle
import android.os.Process
import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.SystemOperation
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.ipc.IFloeSystemService
import com.floe.android.rootsystem.policy.AccessPolicy
import com.floe.android.rootsystem.policy.GrantRegistry
import com.floe.android.rootsystem.policy.PathPolicy
import com.floe.android.rootsystem.policy.ProtectedTargets
import java.io.File

/**
 * The typed privileged service implementation.
 *
 * Every entry point checks: caller UID/appId/user against the verified Floe
 * package identity, a live unrevoked/unexpired grant matching task/run/epoch,
 * the closed operation, the scope (including write permission) and cancellation
 * before and after the operation. There is no raw transact, shell, binder
 * forwarding or cross-app export path.
 */
internal class FloeSystemServiceBinder(
    private val identity: ServerIdentity,
    private val operations: SystemOperations,
    private val registry: GrantRegistry,
    private val mode: String,
    private val onStop: () -> Unit,
) : IFloeSystemService.Stub() {

    // Includes the stable Floe parent, not only the package that launched this
    // service: the runtime component is a sibling applicationId.
    private val ownPackages = identity.protectedPackages

    override fun protocolVersion(): Int = BinderProtocol.VERSION

    override fun ping(): Boolean = true

    override fun describe(): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        return identity.describe(registry.currentGeneration(), capabilities())
    }

    override fun registerGrant(grant: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val request = BinderProtocol.parseGrant(grant) ?: return BinderProtocol.failure("grant_shape")
        return when (val result = registry.register(request, ::validateScope)) {
            is GrantRegistry.Registration.Ok -> BinderProtocol.ok().apply {
                putString(BinderProtocol.KEY_GRANT_ID, result.grantId)
                putLong(BinderProtocol.KEY_EXPIRES_AT, request.expiresAtMillis)
            }
            is GrantRegistry.Registration.Rejected -> BinderProtocol.failure(result.code)
        }
    }

    override fun revokeGrant(grantId: String?) {
        requireCaller()
        if (grantId.isNullOrBlank() || grantId.length > 128) throw SecurityException("grant")
        registry.revoke(grantId)
    }

    override fun revokeAllGrants() {
        requireCaller()
        registry.revokeAll()
    }

    override fun fileList(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val parsed = parse(request, SystemOperation.FILE_LIST) ?: return BinderProtocol.failure("request")
        val (claim, scope) = parsed
        if (!check(claim, SystemOperation.FILE_LIST, scope.scopeId, write = false)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val req = request!!
            val entries = operations.fileList(
                scope,
                req.getString(BinderProtocol.KEY_RELATIVE_PATH) ?: "",
                req.getInt(BinderProtocol.KEY_MAX_ENTRIES, BinderProtocol.MAX_LIST),
            ) { registry.isCancelled(claim.requestId) }
            if (registry.isCancelled(claim.requestId)) {
                BinderProtocol.failure("cancelled")
            } else {
                BinderProtocol.ok().apply {
                    putParcelableArray(BinderProtocol.KEY_ENTRIES, BinderProtocol.entryBundles(entries))
                }
            }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun fileRead(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val parsed = parse(request, SystemOperation.FILE_READ) ?: return BinderProtocol.failure("request")
        val (claim, scope) = parsed
        if (!check(claim, SystemOperation.FILE_READ, scope.scopeId, write = false)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val result = operations.fileRead(
                scope,
                request!!.getString(BinderProtocol.KEY_RELATIVE_PATH) ?: "",
                request.getLong(BinderProtocol.KEY_OFFSET, 0),
                request.getInt(BinderProtocol.KEY_MAX_BYTES, 64 * 1024),
            )
            if (registry.isCancelled(claim.requestId)) {
                BinderProtocol.failure("cancelled")
            } else {
                BinderProtocol.ok().apply {
                    putByteArray(BinderProtocol.KEY_DATA, result.bytes)
                    putBoolean(BinderProtocol.KEY_TRUNCATED, result.truncated)
                }
            }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun fileWrite(request: Bundle?, data: ByteArray?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val (claim, scope) = parse(request, SystemOperation.FILE_WRITE) ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.FILE_WRITE, scope.scopeId, write = true)) {
            return BinderProtocol.failure("denied")
        }
        if (data == null || data.size > BinderProtocol.MAX_WRITE_BYTES) {
            return BinderProtocol.failure("write_too_large")
        }
        return try {
            val receipt = operations.fileWrite(
                scope,
                request!!.getString(BinderProtocol.KEY_RELATIVE_PATH) ?: "",
                data,
                request.getBoolean(BinderProtocol.KEY_OVERWRITE, false),
            )
            if (registry.isCancelled(claim.requestId)) {
                BinderProtocol.failure("cancelled")
            } else {
                BinderProtocol.ok().apply {
                    putInt(BinderProtocol.KEY_BYTES_WRITTEN, receipt.bytesWritten)
                    putBoolean(BinderProtocol.KEY_ATOMIC, receipt.atomic)
                }
            }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun fileMove(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val (claim, scope) = parse(request, SystemOperation.FILE_MOVE) ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.FILE_MOVE, scope.scopeId, write = true)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            operations.fileMove(
                scope,
                request!!.getString(BinderProtocol.KEY_FROM_PATH) ?: "",
                request.getString(BinderProtocol.KEY_TO_PATH) ?: "",
                request.getBoolean(BinderProtocol.KEY_OVERWRITE, false),
            )
            if (registry.isCancelled(claim.requestId)) BinderProtocol.failure("cancelled")
            else BinderProtocol.ok()
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun fileDelete(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val (claim, scope) = parse(request, SystemOperation.FILE_DELETE) ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.FILE_DELETE, scope.scopeId, write = true)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val receipt = operations.fileDelete(
                scope,
                request!!.getString(BinderProtocol.KEY_RELATIVE_PATH) ?: "",
                request.getBoolean(BinderProtocol.KEY_RECURSIVE, false),
            ) { registry.isCancelled(claim.requestId) }
            if (registry.isCancelled(claim.requestId)) {
                BinderProtocol.failure("cancelled")
            } else {
                BinderProtocol.ok().apply { putInt(BinderProtocol.KEY_DELETED, receipt.deleted) }
            }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun processQuery(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val claim = parseClaimOnly(request, SystemOperation.PROCESS_QUERY)
            ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.PROCESS_QUERY, null, write = false)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val records = operations.processQuery(
                request!!.getString(BinderProtocol.KEY_FILTER),
                request.getInt(BinderProtocol.KEY_MAX_ENTRIES, 200),
            )
            val bundles = records.map {
                Bundle().apply {
                    putInt("pid", it.pid)
                    putInt("uid", it.uid)
                    putString("name", it.name)
                }
            }.toTypedArray()
            BinderProtocol.ok().apply { putParcelableArray(BinderProtocol.KEY_PROCESSES, bundles) }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun serviceQuery(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val claim = parseClaimOnly(request, SystemOperation.SERVICE_QUERY)
            ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.SERVICE_QUERY, null, write = false)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val services = operations.serviceQuery(request!!.getInt(BinderProtocol.KEY_MAX_ENTRIES, 200))
            val bundles = services.map {
                Bundle().apply {
                    putString("process", it.processName)
                    putString("className", it.className)
                    putInt("pid", it.pid)
                    putBoolean("foreground", it.foreground)
                }
            }.toTypedArray()
            BinderProtocol.ok().apply { putParcelableArray(BinderProtocol.KEY_SERVICES, bundles) }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun packageQuery(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val claim = parseClaimOnly(request, SystemOperation.PACKAGE_QUERY)
            ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.PACKAGE_QUERY, null, write = false)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val query = operations.packageQuery(
                request!!.getString(BinderProtocol.KEY_PACKAGE_NAME),
                request.getBoolean(BinderProtocol.KEY_INCLUDE_SYSTEM, true),
                request.getInt(BinderProtocol.KEY_MAX_ENTRIES, 200),
            ) { registry.isCancelled(claim.requestId) }
            val bundles = query.packages.map {
                Bundle().apply {
                    putString("packageName", it.packageName)
                    putInt("uid", it.uid)
                    putLong("versionCode", it.versionCode)
                    putBoolean("system", it.system)
                    putBoolean("enabled", it.enabled)
                    putBoolean("running", it.running)
                }
            }.toTypedArray()
            BinderProtocol.ok().apply {
                putParcelableArray(BinderProtocol.KEY_PACKAGES, bundles)
                putBoolean(BinderProtocol.KEY_TRUNCATED, query.truncated)
            }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun networkDiagnostics(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val claim = parseClaimOnly(request, SystemOperation.NETWORK_DIAGNOSTICS)
            ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.NETWORK_DIAGNOSTICS, null, write = false)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val diagnostics = operations.networkDiagnostics()
            val interfaces = diagnostics.interfaces.map {
                Bundle().apply {
                    putString("name", it.name)
                    putBoolean("up", it.up)
                    putStringArray("addresses", it.addresses.toTypedArray())
                }
            }.toTypedArray()
            val routes = diagnostics.routes.map {
                Bundle().apply {
                    putString("interfaceName", it.interfaceName)
                    putString("destination", it.destination)
                    putString("gateway", it.gateway)
                    putBoolean("defaultRoute", it.defaultRoute)
                }
            }.toTypedArray()
            BinderProtocol.ok().apply {
                putParcelableArray(BinderProtocol.KEY_INTERFACES, interfaces)
                putParcelableArray(BinderProtocol.KEY_ROUTES, routes)
                putStringArray(BinderProtocol.KEY_TRANSPORTS, diagnostics.activeTransports.toTypedArray())
            }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun managePackage(request: Bundle?): Bundle {
        if (!callerAllowed()) return BinderProtocol.failure("caller")
        val claim = parseClaimOnly(request, SystemOperation.PACKAGE_FORCE_STOP)
            ?: return BinderProtocol.failure("request")
        if (!check(claim, SystemOperation.PACKAGE_FORCE_STOP, null, write = true)) {
            return BinderProtocol.failure("denied")
        }
        return try {
            val receipt = operations.forceStopPackage(
                request!!.getString(BinderProtocol.KEY_PACKAGE_NAME) ?: "",
                request.getInt(BinderProtocol.KEY_USER_ID, 0),
            )
            if (registry.isCancelled(claim.requestId)) {
                BinderProtocol.failure("cancelled")
            } else {
                BinderProtocol.ok().apply {
                    putBundle(
                        BinderProtocol.KEY_PACKAGE_RESULT,
                        Bundle().apply {
                            putString("packageName", receipt.packageName)
                            putInt("userId", receipt.userId)
                            putString("operation", receipt.operation)
                            putBoolean(BinderProtocol.KEY_STILL_RUNNING, receipt.stillRunning)
                        },
                    )
                }
            }
        } catch (e: SystemOperations.OpException) {
            BinderProtocol.failure(e.code)
        } catch (_: Throwable) {
            BinderProtocol.failure("io")
        }
    }

    override fun cancel(requestId: String?) {
        requireCaller()
        if (requestId.isNullOrBlank() || requestId.length > 128) return
        registry.cancel(requestId)
    }

    override fun stopOwnedService(request: Bundle?) {
        requireCaller()
        val expectedPid = request?.getInt(BinderProtocol.KEY_EXPECTED_PID) ?: -1
        if (expectedPid != Process.myPid()) throw SecurityException("pid")
        registry.revokeAll()
        onStop()
    }

    private fun capabilities(): List<String> = buildList {
        add("files")
        add("process")
        add("service")
        add("package")
        add("network")
        add("package.forceStop")
        add(if (mode == AccessPolicy.MODE_ROOT) "root.uid0" else "adb.shell")
    }

    private fun callerAllowed(): Boolean =
        identity.callerAllowed(Binder.getCallingUid(), Binder.getCallingPid())

    private fun requireCaller() {
        if (!callerAllowed()) throw SecurityException("caller")
    }

    private fun parse(
        bundle: Bundle?,
        expected: SystemOperation,
    ): Pair<OperationClaim, ScopeRoot>? {
        val claim = BinderProtocol.parseClaim(bundle) ?: return null
        if (BinderProtocol.parseOperation(bundle) != expected) return null
        val scopeId = bundle?.getString(BinderProtocol.KEY_SCOPE_ID) ?: return null
        val scope = registry.scope(claim, scopeId) ?: return null
        return claim to scope
    }

    private fun parseOrThrow(bundle: Bundle?, expected: SystemOperation): Pair<OperationClaim, ScopeRoot> =
        parse(bundle, expected) ?: throw SecurityException("request")

    private fun parseClaimOnly(bundle: Bundle?, expected: SystemOperation): OperationClaim? {
        val claim = BinderProtocol.parseClaim(bundle) ?: return null
        if (BinderProtocol.parseOperation(bundle) != expected) return null
        return claim
    }

    private fun check(
        claim: OperationClaim,
        operation: SystemOperation,
        scopeId: String?,
        write: Boolean,
    ): Boolean {
        return when (registry.check(claim, operation, scopeId, write)) {
            is GrantRegistry.Verdict.Ok -> true
            is GrantRegistry.Verdict.Rejected -> false
        }
    }

    private fun validateScope(scope: ScopeRoot): String? {
        PathPolicy.validateScopeBase(scope.path, ownPackages, scope.writable)?.let { return it }
        val root = try {
            File(scope.path).canonicalFile
        } catch (_: Throwable) {
            return "scope"
        }
        // Re-validate the resolved base: `/storage/self/primary` or a
        // `/data/data` alias may canonicalize to a different allowed path, and
        // a link to a platform/private tree must not inherit a writable grant.
        PathPolicy.validateScopeBase(root.path, ownPackages, scope.writable)?.let { return it }
        if (!root.isDirectory) return "scope_missing"
        if (!root.canRead()) return "scope_unreadable"
        if (scope.writable && !root.canWrite()) return "scope_not_writable"
        if (ProtectedTargets.isProtectedPath(root.path, ownPackages)) return "protected"
        if (scope.writable && ProtectedTargets.isReadOnlySystemPath(root.path)) return "scope_read_only"
        return null
    }
}
