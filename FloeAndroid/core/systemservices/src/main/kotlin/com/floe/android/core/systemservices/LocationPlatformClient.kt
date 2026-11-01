// SPDX-License-Identifier: MPL-2.0
//
// Real one-shot Android location access. ONE fix per call; there is no
// background, continuous or historical location tracking here. The App screen
// requests the permission; a model tool can never open the system dialog.

package com.floe.android.core.systemservices

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class LocationPlatformClient(
    context: Context,
    private val locationManager: LocationManager? =
        context.applicationContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager,
) : LocationService {
    private val appContext = context.applicationContext

    override fun capability(evidence: PermissionEvidence): LocationCapability {
        val manager = locationManager
        if (manager == null) {
            return LocationCapability(false, false, SystemPermission.UNAVAILABLE, false)
        }
        val fine = appContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val coarse = appContext.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val permission = when {
            fine -> SystemPermission.GRANTED
            coarse -> SystemPermission.GRANTED
            evidence.locationRequested -> SystemPermission.DENIED
            else -> SystemPermission.NOT_DETERMINED
        }
        val services = try {
            manager.isLocationEnabled
        } catch (_: RuntimeException) {
            false
        }
        return LocationCapability(
            hardwareAvailable = true,
            servicesEnabled = services,
            permission = permission,
            precise = fine,
        )
    }

    override suspend fun currentFix(timeoutMs: Long): LocationFixRow {
        val manager = locationManager ?: throw SystemServiceFailure(
            SystemServiceFailureCode.LOCATION_UNAVAILABLE,
            "this device has no location service",
        )
        val fine = appContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val coarse = appContext.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.PERMISSION_DENIED,
                "location permission is not granted",
            )
        }
        val services = try {
            manager.isLocationEnabled
        } catch (_: RuntimeException) {
            false
        }
        if (!services) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.LOCATION_SERVICES_DISABLED,
                "location services are disabled",
            )
        }
        val providers = (if (fine) {
            listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        } else {
            listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER)
        }).filter { provider ->
            try {
                manager.isProviderEnabled(provider)
            } catch (_: RuntimeException) {
                false
            }
        }
        if (providers.isEmpty()) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.LOCATION_UNAVAILABLE,
                "no enabled location provider is available",
            )
        }

        val provider = providers.first()
        val result = withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine<Location> { continuation ->
                val resumed = AtomicBoolean(false)
                val handler = Handler(Looper.getMainLooper())
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        if (!isValid(location)) return
                        if (!continuation.isActive) {
                            try {
                                manager.removeUpdates(this)
                            } catch (_: RuntimeException) {
                            }
                            return
                        }
                        if (resumed.compareAndSet(false, true)) {
                            try {
                                manager.removeUpdates(this)
                            } catch (_: RuntimeException) {
                            }
                            continuation.resume(location)
                        }
                    }

                    @Deprecated("Deprecated in the platform API on older Android versions")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

                    override fun onProviderEnabled(provider: String) {}

                    override fun onProviderDisabled(provider: String) {
                        if (!continuation.isActive) return
                        if (resumed.compareAndSet(false, true)) {
                            try {
                                manager.removeUpdates(this)
                            } catch (_: RuntimeException) {
                            }
                            continuation.resumeWithException(
                                SystemServiceFailure(
                                    SystemServiceFailureCode.LOCATION_SERVICES_DISABLED,
                                    "the location provider was disabled",
                                ),
                            )
                        }
                    }
                }
                continuation.invokeOnCancellation {
                    handler.post {
                        try {
                            manager.removeUpdates(listener)
                        } catch (_: RuntimeException) {
                        }
                    }
                }
                try {
                    manager.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
                } catch (security: SecurityException) {
                    if (resumed.compareAndSet(false, true)) {
                        continuation.resumeWithException(
                            SystemServiceFailure(
                                SystemServiceFailureCode.PERMISSION_DENIED,
                                "location permission was revoked",
                            ),
                        )
                    }
                } catch (failure: RuntimeException) {
                    if (resumed.compareAndSet(false, true)) {
                        continuation.resumeWithException(
                            SystemServiceFailure(
                                SystemServiceFailureCode.LOCATION_UNAVAILABLE,
                                "the location provider could not start",
                                detail = failure.javaClass.simpleName.take(64),
                            ),
                        )
                    }
                }
            }
        }
        val location = result ?: throw SystemServiceFailure(
            SystemServiceFailureCode.LOCATION_TIMED_OUT,
            "a location fix did not arrive within $timeoutMs ms",
        )
        return LocationFixRow(
            latitude = location.latitude,
            longitude = location.longitude,
            accuracyMeters = location.accuracy.toDouble(),
            timestamp = Instant.ofEpochMilli(location.time),
            precise = fine,
            provider = provider.substringAfterLast('.'),
        )
    }

    private fun isValid(location: Location): Boolean {
        val latitude = location.latitude
        val longitude = location.longitude
        return location.accuracy >= 0f &&
            latitude.isFinite() && latitude in -90.0..90.0 &&
            longitude.isFinite() && longitude in -180.0..180.0
    }
}
