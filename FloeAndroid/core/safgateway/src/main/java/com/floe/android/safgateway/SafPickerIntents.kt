// SPDX-License-Identifier: MPL-2.0
package com.floe.android.safgateway

import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract

/**
 * Platform-side picker construction. JVM tests do not touch this (Intent is a
 * framework class); it is intentionally trivial: turn a [PickRequestSpec] into
 * the standard SAF action Intent, and read EXACTLY the system result back into
 * [SafGrantGateway.acceptPickResult] inputs. No permission flags are invented,
 * no result URI is rewritten, no MANAGE_EXTERNAL_STORAGE or legacy path
 * fallback exists anywhere in this module.
 */
object SafPickerIntents {

    fun from(spec: PickRequestSpec, openableCategory: Boolean = true): Intent {
        val intent = when (spec.kind) {
            PickKind.OPEN_DOCUMENT -> Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                if (openableCategory) addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                if (spec.mimeTypes.isNotEmpty()) {
                    putExtra(Intent.EXTRA_MIME_TYPES, spec.mimeTypes.toTypedArray())
                }
                if (spec.allowMultiple) putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
            PickKind.OPEN_TREE -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                // Note (target 30+ honored by the platform UI itself): internal and
                // removable-volume roots and Download/Android data/obb roots cannot
                // be selected. We surface that as an honest UI limit; no bypass.
            }
            PickKind.CREATE_DOCUMENT -> Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = spec.mimeTypes.firstOrNull() ?: "*/*"
                spec.suggestedName?.let { putExtra(Intent.EXTRA_TITLE, it) }
                // ACTION_CREATE_DOCUMENT creates a DISTINCT document; it never
                // overwrites a same-name one (verified platform behavior).
            }
        }
        spec.initialDirectory?.let {
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(it.uriString))
        }
        return intent
    }

    /** Result plumbing helpers: pass these verbatim into acceptPickResult. */
    fun resultUriString(data: Intent?): String? = data?.dataString

    fun resultFlags(data: Intent?): Int = data?.flags ?: 0
}
