/* -*- tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This Source Code Form is derived from the Collabora Online / LibreOffice
 * android lib (upstream COWebView.java) and is subject to the terms of the
 * Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed
 * with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Floe G05-R1: the client is constructed with the session's bounded transport
 * configuration instead of a bare no-arg WebViewClient.
 */
package org.libreoffice.androidlib

import android.content.Context
import android.util.AttributeSet
import android.webkit.WebView

class COWebView(
    context: Context,
    mediaRootPrefixes: List<String>,
    socketHost: MobileSocket.SocketHost,
) : WebView(context) {

    private val destroyed = java.util.concurrent.atomic.AtomicBoolean(false)

    override fun destroy() {
        if (destroyed.compareAndSet(false, true)) super.destroy()
    }

    private val coClient = COWebViewClient(mediaRootPrefixes, socketHost)

    init {
        setWebViewClient(coClient)
    }

    constructor(
        context: Context,
        attrs: AttributeSet?,
        mediaRootPrefixes: List<String>,
        socketHost: MobileSocket.SocketHost,
    ) : this(context, mediaRootPrefixes, socketHost)

    override fun getWebViewClient(): COWebViewClient = coClient
}
