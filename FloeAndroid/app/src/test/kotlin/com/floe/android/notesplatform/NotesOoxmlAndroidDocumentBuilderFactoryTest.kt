// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import javax.xml.parsers.DocumentBuilder
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for the actual Android platform contract that made every authored
 * Office blank fail at the prepare phase with "Couldn't prepare this document":
 *
 * AOSP libcore's `DocumentBuilderFactory.setXIncludeAware(boolean)` always
 * throws `UnsupportedOperationException`, including for `false`. The real
 * `NotesOoxmlTemplates.parseXml` used to call that setter unguarded, the
 * exception was swallowed by `parseXml`, and validation returned
 * `contentTypesInvalid` for every DOCX/XLSX/PPTX on device while the host JVM
 * (Xerces) accepted the same call.
 *
 * [AndroidLikeDocumentBuilderFactory] reproduces exactly that contract on the
 * host JVM; [NotesOoxmlTemplates.validate] must still validate the authored
 * containers when the platform factory cannot be configured for XInclude.
 */
class NotesOoxmlAndroidDocumentBuilderFactoryTest {

    @Test
    fun authoredOfficeBlanksValidateWithAnAndroidLikeFactory() {
        for (kind in NotesOoxmlKind.entries) {
            val bytes = NotesOoxmlTemplates.create(kind, "G06WordPhaseProbe")
            val validation = NotesOoxmlTemplates.validate(
                bytes,
                kind,
                AndroidLikeDocumentBuilderFactory(),
            )
            assertTrue("$kind: ${validation.reason}", validation.ok)
        }
    }

    /**
     * Delegates everything to the host JVM factory except the XInclude surface,
     * which mirrors AOSP libcore (both the setter and the getter throw).
     */
    private class AndroidLikeDocumentBuilderFactory : DocumentBuilderFactory() {
        private val delegate = DocumentBuilderFactory.newInstance()

        override fun newDocumentBuilder(): DocumentBuilder = delegate.newDocumentBuilder()

        override fun setAttribute(name: String, value: Any) = delegate.setAttribute(name, value)

        override fun getAttribute(name: String): Any = delegate.getAttribute(name)

        override fun setFeature(name: String, value: Boolean) = delegate.setFeature(name, value)

        override fun getFeature(name: String): Boolean = delegate.getFeature(name)

        override fun setNamespaceAware(awareness: Boolean) {
            delegate.isNamespaceAware = awareness
        }

        override fun setValidating(validating: Boolean) {
            delegate.isValidating = validating
        }

        override fun setIgnoringElementContentWhitespace(whitespace: Boolean) {
            delegate.isIgnoringElementContentWhitespace = whitespace
        }

        override fun setCoalescing(coalescing: Boolean) {
            delegate.isCoalescing = coalescing
        }

        override fun setIgnoringComments(ignore: Boolean) {
            delegate.isIgnoringComments = ignore
        }

        override fun setExpandEntityReferences(expand: Boolean) {
            delegate.isExpandEntityReferences = expand
        }

        override fun setXIncludeAware(state: Boolean) {
            throw UnsupportedOperationException("This parser does not support XInclude")
        }

        override fun isXIncludeAware(): Boolean =
            throw UnsupportedOperationException("This parser does not support XInclude")
    }
}
