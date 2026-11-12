// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlAction
import com.floe.android.phonecontrol.PhoneControlLimits
import com.floe.android.phonecontrol.PhoneControlScrollDirection
import com.floe.android.phonecontrol.PhoneControlSwipeDirection
import org.json.JSONObject

/**
 * Pure host-side parsing of `device.act` arguments into the phone-control
 * action model, kept out of [DeviceAccessHost] so the sensitive-input wire
 * rules are JVM-testable without an Android context.
 *
 * Wire rules for action=setText:
 *  - EXACTLY one present text key: `text` for ordinary content, or the
 *    explicit `sensitiveText` parameter for a credential the user already
 *    provided in this authorized task. No vault prerequisite.
 *  - The value must be a real JSON String. A missing key, JSON null, or a
 *    coerced number/boolean/object is refused BEFORE dispatch: org.json's
 *    `optString` would silently turn them into an empty payload, and an
 *    accidental implicit clear of a live field is never acceptable. Only an
 *    explicit empty String is a valid clear.
 *  - Both keys together are mutually exclusive and refused as invalid;
 *    there is no silent fallback from `sensitiveText` to `text`.
 *  - A `sensitiveText` payload becomes a sensitive SetText dispatch: the
 *    exact bytes go to the phone-control session once. Nothing here logs,
 *    echoes, persists or retries the payload. Redaction of BOTH keys before
 *    persistence and non-replayability are enforced upstream by the shared
 *    Swift ToolArgumentSanitizer, because persistence happens before the
 *    host ever learns the target field's protection.
 *
 * Observation rule (enforced by [request], NOT by the advertised schema):
 *  - every action except `launch` must carry a non-empty `observationId`
 *    taken from the LATEST `device.observe` result of this run; `launch`
 *    alone may omit it (the approved current-navigation launch path);
 *  - the trusted catalog schema stays inside the closed JSON-Schema subset
 *    the shared Swift bind enforces, and that subset cannot express a
 *    conditional `required` — any `oneOf`/`if`/`then` keyword would refuse
 *    the WHOLE catalog at bind time. So the rule is decided here and the
 *    host maps [Request.MissingObservation] to the precise, static and
 *    bounded `device_observation_required` failure code instead of folding
 *    it into `invalid_arguments`. The exact legacy `phone_observation_required`
 *    spelling remains a closed decoder alias for historical persisted
 *    receipts; new model-visible results always use the canonical token;
 *  - malformed action arguments keep the original precedence and still
 *    classify as [Request.InvalidArguments] even when `observationId` is
 *    also absent.
 */
internal object PhoneActionArguments {

    /**
     * Exact host failure code for [Request.MissingObservation]. It matches
     * the mailbox failure-code grammar (ASCII letter first, then
     * alphanumeric/`_`/`-`, at most 64 characters) so it survives
     * [BoundedResultText.token] unchanged, and the trusted catalog's
     * `device.act` description teaches the same token so the model can
     * recover with a fresh device.observe instead of guessing. The
     * `phone_` prefix is retained as a closed legacy decoder spelling, never
     * emitted in new results.
     */
    const val OBSERVATION_REQUIRED_CODE = "device_observation_required"

    /** Historical persisted spelling; recognized only by legacy decoders. */
    const val LEGACY_OBSERVATION_REQUIRED_CODE = "phone_observation_required"

    /** The host-side `device.act` contract decision for one argument object. */
    sealed interface Request {
        /** Parsed action plus the observation it names ("" = launch path). */
        data class Dispatch(
            val action: PhoneControlAction,
            val observationId: String,
        ) : Request

        /** Well-formed non-launch action whose `observationId` was omitted. */
        data object MissingObservation : Request

        /** Malformed action arguments; identical to [PhoneActionArguments.parse] refusal. */
        data object InvalidArguments : Request
    }

    fun parse(arguments: JSONObject): PhoneControlAction? {
        val action = arguments.optString("action")
        val nodeRef = arguments.optString("nodeRef")
        fun validRef(): Boolean =
            nodeRef.isNotEmpty() && nodeRef.length <= 16 &&
                nodeRef.all { it.isLetterOrDigit() }
        return when (action) {
            "click" -> if (validRef()) PhoneControlAction.Click(nodeRef) else null
            "setText" -> {
                val hasText = arguments.has("text")
                val hasSensitiveText = arguments.has("sensitiveText")
                // Exactly one present key; a missing pair is NOT an implicit
                // clear.
                if (hasText == hasSensitiveText) return null
                // Strict type check: `opt` keeps JSON null as the NULL
                // sentinel and never coerces numbers/booleans/objects into
                // strings, so only a real String dispatches.
                val raw = if (hasSensitiveText) {
                    arguments.opt("sensitiveText")
                } else {
                    arguments.opt("text")
                }
                val payload = raw as? String ?: return null
                if (!validRef() || payload.length > PhoneControlLimits.MAX_SET_TEXT_CHARS) {
                    null
                } else {
                    PhoneControlAction.SetText(nodeRef, payload, sensitive = hasSensitiveText)
                }
            }
            "scroll" -> {
                val direction = when (arguments.optString("direction")) {
                    "forward" -> PhoneControlScrollDirection.FORWARD
                    "backward" -> PhoneControlScrollDirection.BACKWARD
                    else -> null
                }
                if (!validRef() || direction == null) null
                else PhoneControlAction.Scroll(nodeRef, direction)
            }
            "swipe" -> {
                val direction = when (arguments.optString("direction")) {
                    "up" -> PhoneControlSwipeDirection.UP
                    "down" -> PhoneControlSwipeDirection.DOWN
                    "left" -> PhoneControlSwipeDirection.LEFT
                    "right" -> PhoneControlSwipeDirection.RIGHT
                    else -> null
                }
                if (!validRef() || direction == null) null
                else PhoneControlAction.Swipe(nodeRef, direction)
            }
            "back" -> PhoneControlAction.Back
            "home" -> PhoneControlAction.Home
            "launch" -> {
                val pkg = arguments.optString("packageName")
                if (pkg.isBlank() || pkg.length > PhoneControlLimits.MAX_PACKAGE_CHARS) null
                else PhoneControlAction.Launch(pkg)
            }
            else -> null
        }
    }

    /**
     * Full `device.act` decision used by the host dispatch: [parse] first
     * (malformed arguments keep the exact original refusal), then the
     * non-launch observationId rule. A value is NEVER echoed into the
     * classification; only the shape decides.
     */
    fun request(arguments: JSONObject): Request {
        val action = parse(arguments) ?: return Request.InvalidArguments
        val observationId = arguments.optString("observationId")
        return if (observationId.isEmpty() && action !is PhoneControlAction.Launch) {
            Request.MissingObservation
        } else {
            Request.Dispatch(action, observationId)
        }
    }
}
