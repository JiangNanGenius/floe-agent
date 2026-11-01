# Compiled local Bridge action reference

This is a review aid for `floe-ios-automation`. The compiled
`FloeAgent/Sources/FloeIOSAutomation/IOSAutomationActionCatalog.swift` and
`IOSAutomationActionParameters.swift` are authoritative. The `ios.bridge.*`
tool schema is generated from them; unknown action names or parameter names
fail closed.

All actions below are model-exposed through exactly one surface. `config`,
`logs`, `stream_ticket` and `reset` are internal and never model-callable.

## Observe (read-only)

| Action | Required arguments | Optional arguments | Notes |
| --- | --- | --- | --- |
| `device_info` | — | — | Device dimensions, scale and Bridge capabilities. |
| `page_source` | — | `bundle_id`, `filter`, `max_depth`, `max_elements`, `max_children`, `enhanced`, `visible_only` | Accessibility hierarchy as bounded text and stable references. |
| `screen_text` | — | `element_id`, `match`, `scale` | OCR text boxes with grounded coordinates. |
| `screenshot` | — | `scale`, `bundle_id`, `format`, `quality` | Returns a verified image artifact and pixel/point/scale metadata, not base64. |
| `is_locked` | — | — | Checks the lock state. |
| `list_apps` | — | `text`, `element_type` | Installed apps or the opened-history fallback. |
| `resolve_app` | `text` | `country`, `distance` | Resolve a name or keyword to a bundle identifier. |
| `find_element` | `element_id` | `match`, `element_type`, `bundle_id` | Find an element and return a stable reference. |
| `wait` | — | `duration` | Bounded pause, then observe again. |

## Control (mutating)

| Action | Required arguments | Optional arguments | Notes |
| --- | --- | --- | --- |
| `tap` | — (use `ref` or `x`/`y`) | `ref`, `x`, `y`, `settle`, `settle_timeout`, `fast` | One point/ref tap. |
| `double_tap` | — (use `ref` or `x`/`y`) | `ref`, `x`, `y`, `settle`, `settle_timeout` | One double tap. |
| `long_press` | — (use `ref` or `x`/`y`) | `ref`, `x`, `y`, `duration`, `settle`, `settle_timeout` | One long press. |
| `swipe` | — | `x`, `y`, `direction`, `distance`, `velocity`, `fast`, `settle`, `settle_timeout` | Low-level swipe. |
| `page` | — | `direction`, `distance`, `settle`, `settle_timeout` | One screenful without momentum. |
| `collect` | — | `pages`, `direction`, `min_length`, `fresh`, `source` | **Mutating**: pages the live UI. Bounded paging only. |
| `scroll_to_element` | `element_id` | `match`, `element_type`, `direction`, `distance`, `bundle_id` | **Mutating**: scrolls the live UI until the element is visible. |
| `scroll` | — | `direction`, `settle`, `settle_timeout` | Deprecated coarse full-screen scroll; prefer `swipe`/`page`/`scroll_to_element`. |
| `type` | `text` | `clear`, `submit`, `x`, `y`, `fast`, `via`, `settle`, `settle_timeout` | Text is not echoed. A `⟨credential:id⟩` reference may be the entire value only. |
| `clear_text` | — | `settle`, `settle_timeout` | Empty the focused field. |
| `home` | — | — | Press Home; verifies SpringBoard is frontmost. |
| `lock` | — | — | Lock the screen. |
| `unlock` | — | — | Wake the screen; never enters a passcode. |
| `open_url` | `url` | — | Absolute http(s) or third-party deep link. Protected schemes are refused. |
| `launch_app` | `bundle_id` | — | Open an installed app. |
| `activate_app` | `bundle_id` | — | Bring an installed app forward. |
| `terminate_app` | `bundle_id` | — | Terminate a running app. |
| `tap_element` | `element_id` | `match`, `element_type`, `settle`, `settle_timeout` | Find and tap in one call. |
| `find_and_tap` | `element_id` | `match`, `element_type`, `bundle_id`, `fast`, `settle`, `settle_timeout` | Locate and tap with native fallback. |
| `drag` | — | `points`, `from_ref`, `to_ref`, `from_x`, `from_y`, `to_x`, `to_y`, `duration`, `settle`, `settle_timeout` | One uninterrupted single-finger drag. |

## Mutation classification

| Read-only | Mutating |
| --- | --- |
| `device_info`, `page_source`, `screen_text`, `screenshot`, `is_locked`, `list_apps`, `resolve_app`, `find_element`, `wait` | `tap`, `double_tap`, `long_press`, `swipe`, `page`, `collect`, `scroll_to_element`, `scroll`, `type`, `clear_text`, `home`, `lock`, `unlock`, `open_url`, `launch_app`, `activate_app`, `terminate_app`, `tap_element`, `find_and_tap`, `drag` |

`collect` and `scroll_to_element` are intentionally in the mutating column even
if an external schema describes them as reads. They scroll the live UI and
consume the device-input lease.
