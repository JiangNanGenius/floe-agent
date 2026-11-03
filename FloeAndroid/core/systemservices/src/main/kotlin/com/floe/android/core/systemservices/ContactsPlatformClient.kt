// SPDX-License-Identifier: MPL-2.0
//
// Real read-only Android ContactsContract access. This is the ONLY code in
// the App that queries the contacts provider for the C06 system-service lane.
// It performs one bounded scan (maximum 500 contacts), reads at most three
// phone numbers and three e-mail addresses per contact and never writes,
// deletes, calls, messages or opens a URL. There is no UI scrape, no
// all-files access and no account/developer gate.
//
// Literal search is implemented with parameterized LIKE queries over the
// Contacts table (name) or the Data table (organization/phone/e-mail). No
// model text becomes SQL, a column name, a table name or a provider URI.

package com.floe.android.core.systemservices

import android.Manifest
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.CancellationSignal
import android.provider.ContactsContract
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.withContext

class ContactsPlatformClient(context: Context) : ContactsService {
    private val appContext = context.applicationContext
    private val resolver: ContentResolver = appContext.contentResolver

    override fun capability(evidence: PermissionEvidence): ContactsCapability {
        val provider = providerAvailable()
        val granted = readGranted()
        val permission = when {
            granted -> SystemPermission.GRANTED
            evidence.contactsRequested -> SystemPermission.DENIED
            else -> SystemPermission.NOT_DETERMINED
        }
        return ContactsCapability(providerAvailable = provider, permission = permission)
    }

    fun providerAvailable(): Boolean = try {
        val client = resolver.acquireContentProviderClient(ContactsContract.AUTHORITY)
        if (client == null) {
            false
        } else {
            client.close()
            true
        }
    } catch (_: SecurityException) {
        true
    } catch (_: RuntimeException) {
        false
    }

    fun readGranted(): Boolean =
        appContext.checkSelfPermission(Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * One bounded scan. The caller (snapshot store) owns paging and cursors.
     * `truncated` means at least one matching contact exists beyond the
     * 500-row scan cap; `totalCount` is the number of rows actually retained
     * in this scan (never an invented larger count).
     */
    override suspend fun scan(
        query: String?,
        field: ContactField,
    ): Pair<List<ContactRecordRow>, Boolean> = withContext(Dispatchers.IO) {
        if (!readGranted()) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.PERMISSION_DENIED,
                "contacts read permission is not granted",
            )
        }
        if (!providerAvailable()) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.CONTACTS_PROVIDER_ABSENT,
                "the contacts provider is not available",
            )
        }
        val plan = SystemServicesPolicy.contactPlan(
            query = query,
            field = field.wire,
            limit = SystemServicesBounds.MAX_CONTACT_PAGE,
            offset = 0,
        )
        val signal = CancellationSignal()
        currentCoroutineContext().job.invokeOnCompletion { signal.cancel() }
        try {
            val base = when {
                plan.query == null -> scanAll(signal)
                plan.field == ContactField.NAME -> scanByName(plan.query, signal)
                else -> scanByData(plan, signal)
            }
            val retained = base.take(SystemServicesBounds.MAX_CONTACT_SCAN)
            val enriched = enrich(retained, signal)
            enriched to (base.size > retained.size)
        } catch (failure: SystemServiceFailure) {
            throw failure
        } catch (security: SecurityException) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.PERMISSION_DENIED,
                "contacts permission was revoked",
            )
        } catch (failure: RuntimeException) {
            throw SystemServiceFailure(
                SystemServiceFailureCode.CONTACTS_QUERY_FAILED,
                "the contacts provider query failed",
                detail = failure.javaClass.simpleName.take(64),
            )
        }
    }

    private fun scanAll(signal: CancellationSignal): List<ContactRecordRow> =
        queryContacts(
            selection = null,
            args = emptyArray(),
            signal = signal,
            limit = SystemServicesBounds.MAX_CONTACT_SCAN + 1,
        )

    private fun scanByName(query: String, signal: CancellationSignal): List<ContactRecordRow> {
        val selection = "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} LIKE ? ESCAPE '\\'"
        return queryContacts(
            selection = selection,
            args = arrayOf(SystemServicesPolicy.likePattern(query)),
            signal = signal,
            limit = SystemServicesBounds.MAX_CONTACT_SCAN + 1,
        )
    }

    private fun scanByData(
        plan: ContactQueryPlan,
        signal: CancellationSignal,
    ): List<ContactRecordRow> {
        val literal = plan.query ?: return emptyList()
        val needle = SystemServicesPolicy.likePattern(literal)
        val mimeTypes = when (plan.field) {
            ContactField.ORGANIZATION -> listOf(ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE)
            ContactField.PHONE -> listOf(ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
            ContactField.EMAIL -> listOf(ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
            else -> listOf(
                ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE,
                ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,
                ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE,
            )
        }
        val placeholders = mimeTypes.joinToString(",") { "?" }
        val selection = "${ContactsContract.Data.MIMETYPE} IN ($placeholders)" +
            " AND ${ContactsContract.Data.DATA1} LIKE ? ESCAPE '\\'"
        val args = (mimeTypes + needle).toTypedArray()
        val found = LinkedHashMap<String, ContactRecordRow>()
        resolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(
                ContactsContract.Data.CONTACT_ID,
                ContactsContract.Data.DISPLAY_NAME,
                ContactsContract.Data.MIMETYPE,
                ContactsContract.Data.DATA1,
            ),
            selection,
            args,
            "${ContactsContract.Data.CONTACT_ID} ASC",
            signal,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
            val nameIndex = cursor.getColumnIndexOrThrow(ContactsContract.Data.DISPLAY_NAME)
            while (cursor.moveToNext() && found.size <= SystemServicesBounds.MAX_CONTACT_SCAN) {
                if (signal.isCanceled) break
                val id = cursor.getLong(idIndex).toString()
                if (found.containsKey(id)) continue
                found[id] = ContactRecordRow(
                    id = id,
                    displayName = SystemServicesPolicy.sanitizeContactValue(
                        cursor.getString(nameIndex),
                        SystemServicesBounds.MAX_CONTACT_VALUE_CHARACTERS,
                    ),
                    organization = "",
                    phones = emptyList(),
                    emails = emptyList(),
                )
            }
        }
        if (plan.field == ContactField.ANY) {
            // A contact that matches by display name may have no Data row for
            // the searched value; merge that bounded result by stable id.
            val byName = scanByName(literal, signal)
            for (row in byName) {
                if (!found.containsKey(row.id)) found[row.id] = row
                if (found.size > SystemServicesBounds.MAX_CONTACT_SCAN + 1) break
            }
        }
        return found.values.toList()
    }

    private fun queryContacts(
        selection: String?,
        args: Array<String>,
        signal: CancellationSignal,
        limit: Int,
    ): List<ContactRecordRow> {
        val rows = mutableListOf<ContactRecordRow>()
        resolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(
                ContactsContract.Contacts._ID,
                ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
                ContactsContract.Contacts.SORT_KEY_PRIMARY,
            ),
            selection,
            args,
            "${ContactsContract.Contacts.SORT_KEY_PRIMARY} ASC, ${ContactsContract.Contacts._ID} ASC",
            signal,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(ContactsContract.Contacts._ID)
            val nameIndex = cursor.getColumnIndexOrThrow(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY)
            while (cursor.moveToNext() && rows.size < limit) {
                if (signal.isCanceled) break
                rows.add(
                    ContactRecordRow(
                        id = cursor.getLong(idIndex).toString(),
                        displayName = SystemServicesPolicy.sanitizeContactValue(
                            cursor.getString(nameIndex),
                            SystemServicesBounds.MAX_CONTACT_VALUE_CHARACTERS,
                        ),
                        organization = "",
                        phones = emptyList(),
                        emails = emptyList(),
                    ),
                )
            }
        }
        return rows
    }

    private fun enrich(rows: List<ContactRecordRow>, signal: CancellationSignal): List<ContactRecordRow> {
        if (rows.isEmpty()) return rows
        val phones = HashMap<String, MutableList<String>>()
        val emails = HashMap<String, MutableList<String>>()
        val organizations = HashMap<String, String>()
        rows.map { it.id }.chunked(200).forEach { chunk ->
            if (signal.isCanceled) return@forEach
            val placeholders = chunk.joinToString(",") { "?" }
            val selection = "${ContactsContract.Data.CONTACT_ID} IN ($placeholders)" +
                " AND ${ContactsContract.Data.MIMETYPE} IN (?,?,?)"
            val args = chunk.toMutableList<String>().apply {
                add(ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                add(ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE)
                add(ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE)
            }.toTypedArray()
            resolver.query(
                ContactsContract.Data.CONTENT_URI,
                arrayOf(
                    ContactsContract.Data.CONTACT_ID,
                    ContactsContract.Data.MIMETYPE,
                    ContactsContract.Data.DATA1,
                ),
                selection,
                args,
                null,
                signal,
            )?.use { cursor ->
                val idIndex = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
                val mimeIndex = cursor.getColumnIndexOrThrow(ContactsContract.Data.MIMETYPE)
                val valueIndex = cursor.getColumnIndexOrThrow(ContactsContract.Data.DATA1)
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idIndex).toString()
                    val mime = cursor.getString(mimeIndex) ?: continue
                    val value = cursor.getString(valueIndex) ?: continue
                    when (mime) {
                        ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE ->
                            phones.getOrPut(id) { mutableListOf() }.add(value)
                        ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE ->
                            emails.getOrPut(id) { mutableListOf() }.add(value)
                        ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE -> {
                            if (organizations[id].isNullOrBlank()) {
                                organizations[id] = value
                            }
                        }
                    }
                }
            }
        }
        return rows.map { row ->
            val (cleanPhones, cleanEmails) = SystemServicesPolicy.boundedContact(
                phones[row.id].orEmpty(),
                emails[row.id].orEmpty(),
            )
            row.copy(
                organization = SystemServicesPolicy.sanitizeContactValue(
                    organizations[row.id],
                    SystemServicesBounds.MAX_CONTACT_FIELD_CHARACTERS,
                ),
                phones = cleanPhones,
                emails = cleanEmails,
            )
        }
    }
}
