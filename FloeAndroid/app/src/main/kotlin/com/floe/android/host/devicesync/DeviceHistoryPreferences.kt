// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.devicesync

import android.content.Context
import android.util.AtomicFile
import com.floe.android.core.devicelink.FloeDeviceLinkAddress
import java.io.File
import java.io.FileNotFoundException
import java.net.URI
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

internal data class DeviceHistoryPeer(
    val name: String,
    val address: FloeDeviceLinkAddress,
    val sharedConversations: Set<UUID> = emptySet(),
    val workspaceShares: Map<UUID, String> = emptyMap(),
) {
    val id: String get() = address.endpointId
}

internal data class DeviceHistoryPreferences(
    val enabled: Boolean = false,
    val publicRelay: Boolean = false,
    val customRelay: String? = null,
    val port: Int? = null,
    val peers: List<DeviceHistoryPeer> = emptyList(),
) {
    fun shares(): Map<String, Set<UUID>> = peers.associate { it.id to it.sharedConversations }
}

/** Pairings belong to the local installation, alongside the device's Keystore identity. */
internal class DeviceHistoryPreferenceStore(context: Context) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "device-history-settings.json"))

    fun read(): DeviceHistoryPreferences {
        val input = try {
            file.openRead()
        } catch (missing: FileNotFoundException) {
            if (file.baseFile.exists()) throw missing
            return DeviceHistoryPreferences()
        }
        val data = input.use {
            val size = it.channel.size()
            require(size in 1L..MAX_SETTINGS_BYTES.toLong())
            ByteArray(size.toInt()).also { bytes -> java.io.DataInputStream(it).readFully(bytes) }
        }
        require(data.size <= MAX_SETTINGS_BYTES)
        val value = JSONObject(data.decodeToString(throwOnInvalidSequence = true))
        require(value.getInt("version") == 1)
        val rows = value.getJSONArray("peers")
        val peers = List(rows.length()) { index ->
            val row = rows.getJSONObject(index)
            val shared = row.getJSONArray("sharedConversations")
            require(shared.length() <= MAX_SHARED_CONVERSATIONS)
            val sharedIds = (0 until shared.length()).mapTo(mutableSetOf()) {
                UUID.fromString(shared.getString(it))
            }
            val workspace = row.optJSONObject("workspaceShares")
            require((workspace?.length() ?: 0) <= MAX_SHARED_CONVERSATIONS)
            val workspaceShares = workspace?.let { values ->
                values.keys().asSequence().associate { key ->
                    val task = UUID.fromString(key)
                    require(task in sharedIds)
                    task to values.getString(key).also { require(validScope(it)) }
                }
            }.orEmpty()
            DeviceHistoryPeer(
                name = row.getString("name").also { require(it.isNotBlank() && it.length <= 100) },
                address = FloeDeviceLinkAddress.fromJson(row.getJSONObject("address").toString()),
                sharedConversations = sharedIds,
                workspaceShares = workspaceShares,
            )
        }
        require(peers.distinctBy { it.id }.size == peers.size)
        val relay = value.optString("customRelay").takeIf { it.isNotEmpty() }?.let(::validatedRelay)
        val publicRelay = value.getBoolean("publicRelay")
        require(!publicRelay || relay == null)
        return DeviceHistoryPreferences(
            enabled = value.getBoolean("enabled"),
            publicRelay = publicRelay,
            customRelay = relay,
            port = if (value.has("port")) value.getInt("port").also { require(it in 1..65535) } else null,
            peers = peers,
        )
    }

    fun write(value: DeviceHistoryPreferences) {
        val peers = value.peers.map { peer ->
            require(peer.workspaceShares.all { (task, scope) -> task in peer.sharedConversations && validScope(scope) })
            JSONObject()
                .put("name", peer.name)
                .put("address", JSONObject(peer.address.toJson()))
                .put("sharedConversations", JSONArray(peer.sharedConversations.map(UUID::toString)))
                .apply {
                    if (peer.workspaceShares.isNotEmpty()) {
                        put("workspaceShares", JSONObject(peer.workspaceShares.mapKeys { it.key.toString() }))
                    }
                }
        }
        val bytes = JSONObject().put("version", 1)
            .put("enabled", value.enabled)
            .put("publicRelay", value.publicRelay)
            .put("customRelay", value.customRelay)
            .put("port", value.port)
            .put("peers", JSONArray(peers))
            .toString().encodeToByteArray()
        require(bytes.size <= MAX_SETTINGS_BYTES)
        val output = file.startWrite()
        try {
            output.write(bytes)
            file.finishWrite(output)
        } catch (failure: Exception) {
            file.failWrite(output)
            throw failure
        }
    }

    companion object {
        const val MAX_SHARED_CONVERSATIONS = 200
        private const val MAX_SETTINGS_BYTES = 1024 * 1024

        private val nativeWorkspaceScope = Regex("floe[.]workspace[.]v1[.][0-9a-f]{64}")

        fun validScope(text: String): Boolean = nativeWorkspaceScope.matches(text) ||
            (text.length in 1..160 && text.all { it in '0'..'9' || it in 'a'..'z' || it in 'A'..'Z' || it in "-_:" })

        fun validatedRelay(text: String): String? {
            val trimmed = text.trim()
            if (trimmed.isEmpty()) return null
            require(trimmed.encodeToByteArray().size <= 512)
            val url = URI(trimmed)
            require(url.scheme.equals("https", ignoreCase = true) && !url.host.isNullOrEmpty() &&
                url.userInfo == null && url.query == null && url.fragment == null &&
                (url.port == -1 || url.port in 1..65535))
            return url.toASCIIString()
        }
    }
}
