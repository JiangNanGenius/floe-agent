# Floe Browser Protocol 1.0

Floe Browser Protocol is a CDP-shaped control layer for the user-visible
`WKWebView` owned by Floe Agent. It uses only public WebKit APIs and does not
claim wire compatibility with Chrome DevTools Protocol.

## Identity and invalidation

- `sessionID` identifies the in-app browser lifetime.
- `targetID` identifies one visible tab (maximum six).
- `documentID` changes at main-frame commit. Element references from an older
  document fail with `stale`; callers must observe the new document.
- DOM references are stable inside one document and live only in an isolated
  WebKit content world. The table is bounded and disconnected nodes are
  reclaimed.

## Allowlisted method surface

The method envelope supports:

- `Browser.getVersion`
- `Target.getTargets`, `Target.createTarget`, `Target.activateTarget`,
  `Target.closeTarget`
- `Page.navigate`, `Page.reload`, `Page.captureScreenshot`, `Page.waitForLoad`,
  `Page.waitForDOM`, `Page.waitForIdle`
- `DOM.getDocument`
- `Input.dispatchMouseEvent`, `Input.insertText`
- `Runtime.getEvents`

There is intentionally no arbitrary `Runtime.evaluate`. Model-facing tools use
the same engine through narrower `browser.observe`, `browser.events`,
`browser.wait`, `browser.click`, `browser.clickPoint`, `browser.type`,
`browser.scroll`, `browser.navigate`, and `browser.screenshot` contracts.

## Events and waiting

Each tab holds a bounded sequence-numbered queue. Native WebKit delegates emit
main-frame lifecycle and failure events; the isolated DOM probe emits DOM and
document lifecycle events. Consumers resume with `afterSequence` and never
replay an already processed GUI action.

`Page.waitForIdle` is an explicitly approximate condition: main-frame loading
must stop and the DOM must remain unchanged for a bounded quiet interval.
Public `WKWebView` does not expose CDP's request-level Network domain.

## Security boundary

Navigation is limited to public HTTP(S) destinations and rejects credentials in
URLs, loopback, and private-network hosts. Password fields require user takeover
and their values/text are omitted from observations. Protocol parameters are
allowlisted and size-bounded; missing parameters fail closed. Events never
include typed text, page text, or full navigated URLs.

Programmatic pointer and keyboard events are not trusted iOS input. Pages that
require trusted user activation, closed shadow DOM, protected file selection,
payments, credentials, CAPTCHA, or other anti-automation checks must return to
the visible user-controlled browser.
