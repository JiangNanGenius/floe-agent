---
name: floe-ios-automation
description: Observe and control the current iPhone or iPad through the optional, self-signed Floe iOS Bridge companion on the same device. Use only after the user installs and enables this Skill and approves the local pairing inside Bridge.
---

# Local iOS automation

Use the compiled `ios.bridge.*` tools on **this physical iPhone or iPad only**. This Skill has no scripts, shell, SSH, LAN backend, Mac backend or remote-device route. It never bypasses a system prompt, passcode, device lock or the Floe/Bridge authorization UI.

This Skill is optional and is not bundled with Floe. If the tools are absent, ask the user to install and enable it from Skills. Do not install it automatically and do not claim it is available on an older Floe build.

## Before the first device action

1. **Install the companion on the same device.** Floe iOS Bridge is a separate app. The user obtains the official unsigned IPA, signs it with their own Apple developer material, installs it, completes its one-time setup (developer pairing record, local VPN configuration, runtime image) and taps **Start Service** in Bridge. Floe cannot sign, install, start or approve Bridge. A free Apple ID or arbitrary re-signing tool is not guaranteed. The companion requires iOS/iPadOS 26 or later.
2. **Install and enable this Skill.** Review its `credentials`, `device.observe` and `device.interact` grants. The `bridge` connection field is required; its values never live in the Skill package.
3. **Continue setup in chat.** When the user asks to connect, call `ios.bridge.status` first. If Bridge is running and needs pairing, explain that its native confirmation is about to appear, then call `ios.bridge.pair` once. The user approves inside Bridge and returns to this conversation. Recheck status and configuration before continuing the original task. The Skill configuration page remains an optional manual route; do not require the user to find it just to pair from chat. Never ask for a pairing key, token, password or device passcode in chat or put one in a URL. Pairing expires after 30 days without use and can be revoked in Bridge.
4. **Check readiness.** Call `ios.bridge.status` before pairing or whenever a device tool reports that Bridge is unavailable. `configured` is not `ready`: proceed only when the installed Skill is enabled, the current connection revision validates, and a real Bridge status returns ready.

If `skill.config` is available, use `inspect` (secret-free) and `validate` for this Skill at profile `default` and target `local-ios`. Do not use `save` or `bind` for the `bridge` field: it is a native connection, and pairing must go through the native Bridge flow. `validate` performs a real loopback check for the current revision.

Installed and enabled exposes `ios.bridge.status` and, when its grants and connection shape are usable, `ios.bridge.pair`. Only a current validated connection that is actually ready exposes `ios.bridge.observe` and `ios.bridge.control`. Pairing and control require a normal writable task; a read-only or temporary task cannot pair or mutate the device. Observation follows the task's existing tool ceiling.

## Tool surfaces

### `ios.bridge.status`

Read-only. Optional `include_configuration` defaults to true. Returns the current status key, paired/requiresPairing, protocol and engine facts when available, expiry, sensitive-input grant, configuration readiness and `readyForDeviceActions`. It never returns key material. Use it before pairing and after the user returns from Bridge.

### `ios.bridge.pair`

Setup mutation. Optional `client_name` (display label, 1...128 printable UTF-8 bytes) and `replace_existing` (default false). It waits for the owner's decision inside Bridge. Do not call it repeatedly while a pairing is pending; cancel first if the user changes their mind. A successful result does not by itself prove device actions are ready; check status.

### `ios.bridge.observe`

Read-only observation of the current screen:

`device_info`, `page_source`, `screen_text`, `screenshot`, `is_locked`, `list_apps`, `resolve_app`, `find_element`, `wait`.

- Use `page_source` for the accessibility hierarchy and stable element references. Use `screen_text` when text is not exposed accessibly, `find_element` to locate a specific element, and `list_apps`/`resolve_app` before launching an app.
- Coordinates are **points** in the screenshot's point space: `point = pixel / scale`. Do not guess a coordinate that was not grounded by a fresh screenshot or text box.
- `screenshot` returns a verified image artifact plus pixel/point/scale metadata; it does not return a base64 body to the model. Inspect the attached image before coordinate input.
- `wait` pauses for a bounded duration; it is observation, not a substitute for checking the screen afterwards.

### `ios.bridge.control`

Mutating control of the current screen:

`tap`, `double_tap`, `long_press`, `swipe`, `page`, `collect`, `scroll_to_element`, `scroll`, `type`, `clear_text`, `home`, `lock`, `unlock`, `open_url`, `launch_app`, `activate_app`, `terminate_app`, `tap_element`, `find_and_tap`, `drag`.

- **`collect` and `scroll_to_element` are mutating.** They page or scroll the live UI even though the released Bridge schema labels them read. Treat them like any other device change.
- `scroll` is a deprecated coarse full-screen scroll; prefer `swipe`, `page` or `scroll_to_element`.
- Prefer a stable `ref`/`element_id` from a fresh observation over raw coordinates. For `tap`, `double_tap`, `long_press`, `swipe`, `page`, `scroll`, `type` and `drag`, supply either the observed reference or grounded point coordinates as the action contract requires.
- `type.text` is not echoed and is not stored in ordinary results. A normalized `⟨credential:id⟩` reference may be used only as the **entire** text value for an authorized local control call; embedded placeholders are refused. Never ask the user to paste a secret into the conversation.
- `open_url` accepts an absolute http(s) URL or third-party app deep link. The native policy refuses the `floe` and `floe-ios-bridge` schemes, local file/data/javascript schemes and protected targets.
- Floe and Bridge authorization surfaces are protected: automation cannot read the Bridge management screen, tap/type into Floe or Bridge, or open their protected schemes. Do not attempt to bypass this policy.

The compiled tool schema is authoritative for exact parameter names, types and required fields. `references/ACTIONS.md` mirrors the action list and required arguments for review; do not invent missing parameters.

## Operating rules

1. **Observe, act once, observe again.** Do not batch blind mutations. After a successful mutation, inspect the resulting screen before deciding the next step.
2. **One task owns device input.** A normal task keeps persistent input ownership across successive control calls until it finishes, is cancelled, is suspended or its bounded window expires. Another task cannot interleave controls. Do not try to work around `inputBusy` or `deviceBusy`.
3. **Confirm the foreground target.** Coordinate and text actions verify the live foreground app. A declared `bundle_id` must match it. Floe, Bridge and an unverifiable foreground are refused; ask the user to bring the intended app forward.
4. **Respect the user's intent and consent.** Do not use this Skill for hidden monitoring, credential capture, passcode entry, system authentication or bypassing an app's own confirmation. Stop when the user asks to stop.
5. **No automatic retries.** The client never retries a mutation. Handle each outcome explicitly:

| Outcome | What it means | What to do |
| --- | --- | --- |
| `notSent` / definite refusal | The action was refused before dispatch (for example no pairing, locked credentials, protected target, engine not ready, expired window). | Explain the cause and the exact next step. Do not report success. |
| `failed` | The action was dispatched but no successful completion receipt exists. | Observe the screen before deciding whether any further action is needed. |
| `cancelled` | The user or task cancelled the call. A call cancelled after dispatch may have taken effect. | Treat it as unknown after dispatch; observe before acting. |
| `fenced` | A lifecycle change fenced the operation; it may have been dispatched. | Observe; do not retry automatically. |
| `outcomeUnknown` | Bridge could not confirm whether the mutation took effect. | Observe the screen first. Ask the owner to check the device if needed. Never repeat blindly. |

6. **Bridge pause/Stop and backgrounding.** If Bridge is stopped, unreachable, restarting or its engine is not ready, report that exact state and ask the user to open Bridge and start/check the service. A Stop fences pending work; do not retry a mutation until the user restarts and status is ready again. A background execution window may expire; return to Floe and check status before continuing.
7. **Locked, denied, unsupported, outdated.** Unlock the device for locked credentials; the saved pairing is not deleted. A denied pairing is the owner's decision; do not loop or auto-approve. Local automation is unavailable on Mac, Mac Catalyst, iOS-on-Mac and the Simulator. An incompatible Bridge protocol requires updating Bridge; do not downgrade or guess. A missing engine or setup must be fixed in Bridge.
8. **No Mac or remote substitution.** This is not the same-Mac Floe Bridge (`floe-bridge://connect`), not a Mac terminal, not SSH and not a remote Linux guest. Do not route a local-device request through those tools or claim they provide this capability.

## 中文速览

- 仅用于同一台真实 iPhone/iPad 上的 Floe 与单独的 **Floe iOS Bridge** 配套应用；不控制 Mac、模拟器或其他设备，也不提供 shell、SSH 或远端执行。
- 配套应用需由用户自行签名安装（官方 IPA 无签名，iOS/iPadOS 26+），完成一次性设置并在 Bridge 中点“开始服务”。Floe 不能代装、代签、代启动或代批准。
- 先安装并启用本 Skill，确认 `credentials`、`device.observe`、`device.interact` 授权，再在 Skills 中配对。Bridge 会显示原生确认，必须由用户亲自批准。不要在聊天中索要配对密钥、密码或设备密码。
- 只有状态真实 `ready` 才能观察或控制；`configured` 不等于 `ready`。安装/启用只暴露 `ios.bridge.status`，可用时才暴露 `ios.bridge.pair`；真正就绪后才暴露 `ios.bridge.observe` 和 `ios.bridge.control`。
- 先观察再操作；坐标使用截图的点坐标（像素 ÷ scale）。`collect` 和 `scroll_to_element` 会滚动真实界面，属于变更操作。
- `type.text` 不会回显；凭据引用只能作为整个文本值用于已授权的本机控制调用。不要把密码贴进对话。
- Floe 和 Bridge 的授权界面受保护，不能读取、点击、输入或通过 `floe`/`floe-ios-bridge` 链接绕过。
- 变更失败、超时、取消、fenced 或结果未知时不要自动重试；先重新观察屏幕，再决定下一步。Bridge 停止、未运行、引擎未就绪、锁定、拒绝、协议不兼容时必须如实说明并给出明确的下一步。
