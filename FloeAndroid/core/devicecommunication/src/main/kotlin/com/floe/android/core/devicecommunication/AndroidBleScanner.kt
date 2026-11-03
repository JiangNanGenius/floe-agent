// SPDX-License-Identifier: MPL-2.0
//
// BLE permission truth + a bounded foreground scan. No permission request is
// ever launched from here; the App host owns the user action and the dialog.
// Android 12+ uses BLUETOOTH_SCAN/CONNECT; Android 9-11 scan additionally
// requires location permission and the system location switch.

package com.floe.android.core.devicecommunication

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import java.util.LinkedHashMap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

object BlePermissions {
    fun missing(context: Context): List<String> {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return emptyList()
        }
        val required = if (Build.VERSION.SDK_INT >= 31) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return required.filter {
            context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    fun required(context: Context): List<String> {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            return emptyList()
        }
        return if (Build.VERSION.SDK_INT >= 31) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    fun requiresLocationServices(): Boolean = Build.VERSION.SDK_INT < 31

    fun locationServicesEnabled(context: Context): Boolean {
        if (!requiresLocationServices()) return true
        return try {
            val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
            manager.isLocationEnabled
        } catch (_: Throwable) {
            false
        }
    }
}

class AndroidBleScanner(private val context: Context) {
    fun requirements(): BleRequirements {
        val adapter = adapter()
        val supported = context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val enabled = try {
            adapter?.isEnabled == true
        } catch (_: SecurityException) {
            false
        }
        return BleRequirements(
            supported = supported,
            enabled = enabled,
            missingPermissions = BlePermissions.missing(context),
            requiresLocationServices = BlePermissions.requiresLocationServices(),
            locationServicesEnabled = BlePermissions.locationServicesEnabled(context),
        )
    }

    suspend fun scan(durationMillis: Long, maximumResults: Int = DeviceLimits.MAXIMUM_SCAN_RESULTS): List<BleScanResult> {
        val requirements = requirements()
        if (!requirements.supported) {
            throw DeviceCommunicationException(
                DeviceErrorCode.UNSUPPORTED,
                "This device does not support Bluetooth Low Energy.",
            )
        }
        if (requirements.missingPermissions.isNotEmpty()) {
            throw DeviceCommunicationException(
                DeviceErrorCode.PERMISSION_REQUIRED,
                "Nearby devices permission is required to scan.",
            )
        }
        if (!requirements.enabled) {
            throw DeviceCommunicationException(
                DeviceErrorCode.BLUETOOTH_DISABLED,
                "Turn on Bluetooth to scan for devices.",
            )
        }
        if (requirements.requiresLocationServices && !requirements.locationServicesEnabled) {
            throw DeviceCommunicationException(
                DeviceErrorCode.PERMISSION_REQUIRED,
                "Turn on location services to scan for Bluetooth devices on this Android version.",
            )
        }
        val scanner = try {
            adapter()?.bluetoothLeScanner
        } catch (_: SecurityException) {
            null
        } ?: throw DeviceCommunicationException(
            DeviceErrorCode.BLUETOOTH_UNAVAILABLE,
            "Bluetooth scanning is unavailable.",
        )
        val results = LinkedHashMap<String, BleScanResult>()
        val failure = CompletableDeferred<DeviceCommunicationException>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device?.address ?: return
                if (results.size >= maximumResults && !results.containsKey(address)) return
                val name = try {
                    result.scanRecord?.deviceName?.take(80)
                        ?: result.device?.name?.take(80)
                } catch (_: SecurityException) {
                    null
                }
                results[address] = BleScanResult(
                    address = address,
                    name = name?.filter { it.code >= 0x20 }?.ifBlank { null },
                    rssi = result.rssi,
                )
            }

            override fun onScanFailed(errorCode: Int) {
                failure.complete(
                    DeviceCommunicationException(
                        DeviceErrorCode.BLUETOOTH_UNAVAILABLE,
                        "Bluetooth scanning failed ($errorCode).",
                        retryable = true,
                    ),
                )
            }
        }
        try {
            scanner.startScan(callback)
        } catch (error: SecurityException) {
            throw DeviceCommunicationException(
                DeviceErrorCode.PERMISSION_REQUIRED,
                "Nearby devices permission is required to scan.",
            )
        } catch (error: Throwable) {
            throw DeviceCommunicationException(
                DeviceErrorCode.BLUETOOTH_UNAVAILABLE,
                "Bluetooth scanning could not start.",
                retryable = true,
            )
        }
        try {
            withTimeout(durationMillis.coerceIn(1_000, 15_000)) {
                failure.await()
            }
        } catch (_: TimeoutCancellationException) {
            // Expected end of the bounded scan window.
        } finally {
            runCatching { scanner.stopScan(callback) }
        }
        if (failure.isCompleted) throw failure.await()
        return results.values.sortedBy { (it.name ?: it.address).lowercase() }
    }

    private fun adapter(): BluetoothAdapter? = try {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    } catch (_: Throwable) {
        null
    }
}
