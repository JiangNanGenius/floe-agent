# Local Bridge setup and recovery

This reference supports `floe-ios-automation`. It describes the user's real
environment; it is not a second permission model and it does not make the
Skill or companion available on a build that lacks the native tools.

## Requirements

- A physical iPhone or iPad running iOS/iPadOS 26 or later. The Simulator, Mac
  Catalyst, iOS-on-Mac and the Mac Bridge are not supported by this Skill.
- A Floe build that includes the compiled `ios.bridge.*` tools and Skill
  configuration support. If the Skill cannot be installed or the tools do not
  appear, the user must update Floe; do not claim local automation works on an
  older build.
- The separate **Floe iOS Bridge** companion installed on the same device. Check the
  official release centre at https://www.floe-agent.com/releases?platform=ios-bridge
  for the available package and its qualification scope.
  The official package is unsigned; the user re-signs it with their own Apple
  developer material (including the required Network Extension capability),
  installs it and completes its one-time developer setup. Free Apple ID or
  arbitrary re-signing tool compatibility is not promised.
- A current local pairing, approved by the device owner inside Bridge.

## First setup

1. Verify the companion package and its SHA-256 from the official release.
2. Re-sign it with the user's own certificate, provisioning profiles, and
   bundle identifiers; install it on the device. Do not patch identifiers
   inside the executable.
3. Enable Developer Mode and complete any system trust prompt on the device.
4. Generate and import the device's **RemotePairing development record** in
   Bridge. This is not a Lockdown record and is not a client control key.
5. Install Bridge's local VPN configuration and complete any on-device
   passcode prompt.
6. Open Bridge, complete its runtime-image setup, and tap **Start Service**.
   A usable address appears only after Bridge reports real readiness. After a
   reboot, unlock the device and open Bridge; restore follows the user's
   previous run intent but is not an always-on boot promise.
7. In Floe, install and enable this optional Skill and accept its declared
   `credentials`, `device.observe`, and `device.interact` access. In chat,
   ask Floe to connect this device: the assistant checks `ios.bridge.status`
   and calls `ios.bridge.pair` when needed. The Skill's **Local Bridge
   connection** field remains a manual setup route. The default
   configuration profile is `default`; the native target is `local-ios`.
8. Approve the request in Bridge. Floe waits for that native decision; nobody
   can approve it from chat or from the Skill package.
9. Return to Floe and check `ios.bridge.status` until the connection and
   configuration are both ready.

## Everyday use

- Open Bridge and keep the service running while using local automation.
- Check status before a control sequence. `configured` only means the field
  has a saved value; `ready` requires a reachable Bridge, a readable
  device-bound pairing, a valid current connection revision and a ready
  engine.
- A pairing expires after 30 days without use. Bridge can revoke a client.
  Pair again only after the owner approves in Bridge; the old local record is
  replaced only after a new one is saved and verified.
- Pairing and control are unavailable in a read-only or temporary task.
  Observation follows the current task's tool ceiling.

## State and recovery

| State | Meaning | Next step |
| --- | --- | --- |
| Unsupported platform | Floe is not running on a supported physical iPhone/iPad. | Use a supported device; do not try the Mac or Simulator. |
| Companion missing / presence unknown | Bridge is not installed, or its presence cannot be proven from a refused connection. | Install/open Bridge manually, then check again. A refused socket alone is not proof of uninstall. |
| Service off / unavailable | Bridge is installed but not running, or not reachable. | Open Bridge and start the service; check the real address. |
| Needs pairing / pairing invalid / expired / revoked | There is no usable saved pairing, or Bridge no longer recognizes it. | Pair again and approve inside Bridge. Do not delete or overwrite unrelated credentials. |
| Waiting for owner approval | A pairing request is queued in Bridge. | Open Bridge and approve or deny it; do not start a second pairing. |
| Locked credentials | The device-bound Keychain item is unreadable while locked. | Unlock the device; the record is not deleted. |
| Incompatible Bridge | The companion protocol is not supported. | Update Bridge; do not downgrade the client or guess a wire format. |
| Engine not ready | Bridge is reachable and paired, but its automation engine is not ready. | Open Bridge, check its setup, and wait for a real ready state. |
| Ready | A real authenticated status call succeeded. | Observe before acting; use `ios.bridge.control` only for an intended change. |

## Stop, cancel and unknown outcomes

- **Cancel pairing** stops the local wait and asks Bridge to cancel. A late
  approval must not be treated as a successful new pairing.
- **Stop** in Bridge fences pending work. Do not retry a mutation after a
  stop until Bridge is restarted, status is ready and the user still wants the
  action.
- **Cancellation** of a control call may happen before or after dispatch. If
  it may have been dispatched, inspect the screen before doing anything else.
- **Unknown outcome** means the mutation may already have taken effect.
  Observe first. Ask the owner to check the device if observation is
  inconclusive. Never retry blindly.
- **Definite refusal** means nothing was dispatched. Explain the exact
  condition; the user may fix it and explicitly ask again.

## Companion open/return limitation

The published Bridge 1.0 source (`3aed1496`) has no URL scheme. Floe can open
Bridge only when both sides have the additive handoff and the Floe build
configures its optional open URL; otherwise the user opens Bridge manually.
The current App path does not define an automatic return route, so do not
claim that approving in Bridge navigates back to Floe. The outstanding pairing
request is owned by the Floe task and completes when the owner decides; the
user can return manually and check status.

## 中文核对清单

1. 确认是真实 iPhone/iPad，且 Floe 构建包含本机自动化工具。
2. 从官方发布获取 Floe iOS Bridge 未签名 IPA，自行签名并安装；完成开发者配对记录、本地 VPN 和运行镜像设置。
3. 在 Bridge 中点“开始服务”，确认真正可用。
4. 在 Floe 中安装并启用本 Skill，接受 `credentials`、`device.observe`、`device.interact`；在聊天中要求连接本机 Bridge，由助手检查状态并发起配对。也可从技能详情的配置入口手动配对。
5. 在 Bridge 中由用户亲自批准；不要在聊天中传递密钥、密码或设备密码。
6. 只有状态真实 `ready` 才继续；锁定、拒绝、版本不兼容、服务未运行或引擎未就绪时按上表处理。
7. 变更结果未知时先观察屏幕；不要自动重试。Bridge 1.0 没有 URL scheme，打开 Bridge 需要手动操作，不能承诺自动返回。
