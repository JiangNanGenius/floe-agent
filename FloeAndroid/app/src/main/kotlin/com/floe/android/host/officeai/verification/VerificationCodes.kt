// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

/** Short typed refusal codes for the pure OOXML saved-content verifier.
 * Every failure path returns one of these and mutates NOTHING: verification
 * is strictly read-only over the App-owned exported file.
 */
internal object VerificationCodes {
    const val ARTIFACT_MISSING = "artifactMissing"
    const val ARTIFACT_SIZE_INVALID = "artifactSizeInvalid"
    const val ARTIFACT_TOO_LARGE = "artifactTooLarge"
    const val ARTIFACT_SIZE_MISMATCH = "artifactSizeMismatch"
    const val ARTIFACT_DIGEST_INVALID = "artifactDigestInvalid"
    const val ARTIFACT_DIGEST_MISMATCH = "artifactDigestMismatch"
    const val EXPECTED_TOO_LARGE = "expectedTooLarge"
    const val EXPECTED_EMPTY = "expectedEmpty"
    const val UNKNOWN_FORMAT = "unknownFormat"
    const val UNKNOWN_COMMAND = "unknownCommand"
    const val UNKNOWN_CONTENT_KIND = "unknownContentKind"
    const val COMMAND_FORMAT_MISMATCH = "commandFormatMismatch"
    const val ZIP_MALFORMED = "zipMalformed"
    const val ZIP_ENCRYPTED = "zipEncrypted"
    const val ZIP_UNSUPPORTED_METHOD = "zipUnsupportedMethod"
    const val ZIP_TOO_MANY_ENTRIES = "zipTooManyEntries"
    const val ZIP_UNSAFE_ENTRY = "zipUnsafeEntry"
    const val ZIP_UNBOUNDED = "zipUnboundedInflation"
    const val ZIP_PART_TOO_LARGE = "zipPartTooLarge"
    const val PART_MISSING = "partMissing"
    const val XML_UNTRUSTED = "xmlUntrusted"
    const val XML_MALFORMED = "xmlMalformed"
    const val XML_ENCODING_UNSUPPORTED = "xmlEncodingUnsupported"
    const val XML_ENCODING_INVALID = "xmlEncodingInvalid"
    const val PARSER_UNAVAILABLE = "parserUnavailable"
    const val MISSING_PART_INDEX = "missingPartIndex"
    const val MISSING_CELL_ADDRESS = "missingCellAddress"
    const val CELL_ADDRESS_INVALID = "cellAddressInvalid"
    const val TARGET_INDEX_OUT_OF_RANGE = "targetIndexOutOfRange"
    const val RELATION_UNRESOLVED = "relationUnresolved"
    const val TARGET_NOT_WORKSHEET = "targetNotWorksheet"
    const val TARGET_CELL_MISSING = "targetCellMissing"
    const val UNSUPPORTED_FORMULA = "unsupportedFormula"
    const val SHARED_STRING_INVALID = "sharedStringIndexInvalid"
    const val SHARED_STRINGS_MISSING = "sharedStringsMissing"
    const val NUMBER_INTENT_INVALID = "numberIntentInvalid"
    const val FORMULA_INTENT_MISSING_EQUALS = "formulaIntentMissingEquals"
    const val INSPECTOR_ERROR = "inspectorError"
}

/** Bounded-work limits. The artifact cap is fixed by Main at 256 MiB; every
 * other bound aborts early so no path ever buffers the whole artifact in RAM
 * or inflates an unbounded stream.
 */
internal object VerificationLimits {
    const val MAX_ARTIFACT_BYTES: Long = 256L * 1024L * 1024L
    const val MAX_ENTRIES = 2048
    const val MAX_CENTRAL_DIR_BYTES = 16L * 1024L * 1024L
    const val MAX_ENTRY_NAME_BYTES = 1024
    const val MAX_PART_BYTES = 32L * 1024L * 1024L
    const val MIN_INFLATION_ALLOWANCE_BYTES = 1_000_000L
    const val MAX_INFLATION_RATIO = 1000L
    const val MAX_EXPECTED_BYTES = 128L * 1024L
    const val MAX_TEXT_OCCURRENCES = 256
    const val MAX_OCCURRENCE_REPORT = 4096
    const val PREVIEW_MAX_CHARS = 512
    const val LIMITATIONS_CAP = 8
    const val READ_CHUNK_BYTES = 64 * 1024
}

internal object VerificationNotes {
    const val NO_BASELINE = "noBaselineProvided"
    const val BASELINE_UNVERIFIED = "baselineUnverified"
    const val BASELINE_UNREADABLE = "baselineUnreadable"
    const val BASELINE_TARGET_MISMATCH = "baselineTargetMismatch"
    const val BASELINE_TARGET_UNKNOWN = "baselineTargetUnknown"
    const val BASELINE_PART_MISSING = "baselinePartMissing"
    const val PRIOR_SELECTION_MISSING = "priorSelectionMissing"
    const val PRIOR_NOT_IN_BASELINE = "priorNotFoundInBaseline"
    const val DELTA_SEARCH_BOUNDED = "deltaSearchBounded"
    const val VALUE_UNCHANGED = "valueUnchangedNothingProven"
    const val WORD_HEADERS_NOT_INSPECTED = "onlyWordDocumentPartInspected"
    const val STORED_NOT_NUMERIC = "storedValueNotNumeric"
    const val PREVIEW_TRUNCATED = "persistedValuePreviewTruncated"
    const val OCCURRENCES_CAPPED = "occurrenceCountCapped"
    const val DELTA_NOT_SINGLE_EDIT = "savedNotOneEditFromBaseline"
}
