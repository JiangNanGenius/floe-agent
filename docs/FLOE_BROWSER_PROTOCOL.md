# Floe Browser Protocol 1.0

> 文档导航更新 / Documentation navigation updated 2026-10-05: [当前状态 / Current status](CURRENT_STATUS.md) · [中文手册](USER_GUIDE.zh-CN.md) · [English manual](USER_GUIDE.md)。本文带日期的候选、测试与交付结论保留原始适用范围，不视为当前发布状态。Dated evidence below remains scoped to its original source.

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

## Task-scoped takeover (1.7.22 candidate)

`browser.panel` with `requestUser` requests a human browser handoff. Browser
mutation commands return protocol `needsUser` while control is held by the user,
but the enclosing tool result does **not** request suspension of the whole agent
runtime. Other authorized tools remain usable. Browser commands reject a
conversation that does not own the currently bound session.

Return-to-agent writes an atomic outbox event before delivery. Its stable ID is
also the persisted running-input ID. The original conversation/run, browser
session, tab and sanitized page address accompany the notification; query strings,
fragments, URL credentials and form contents are excluded. Earlier document IDs
are invalidated and the model must observe again. Failed delivery retains the ID
for retry. Browser inputs are excluded from automatic queued-follow-up launches;
a terminal run requires explicit continuation. Runtime state updates retry an
unconsumed original-run handoff after recovery.

Explicitly authorized local previews and scoped port rules may allow their exact
loopback origin. This does not open general access to arbitrary private-network
addresses or authorize a different task's services.

用户接管仅阻止模型的浏览器操作，不暂停整个任务。交还通知按事件 ID 持久化并去重，
只投递给原会话／任务。模型再次操作前必须重新观察页面。已结束任务需要明确继续，
不会把交接通知作为新的自动任务启动。通知不含密码、表单内容、地址查询参数或片段。
