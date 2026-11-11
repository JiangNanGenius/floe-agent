<!-- docs-updated: 2026-11-12 -->

> This guide covers Floe for Android (the Android edition of Floe Agent) and its actual shipped workflows, with a focus on self-ADB activation on older Android versions. This guide follows 1.0.0 (versionCode 108); as of 2026-11-12, GitHub marks it as a prerelease — check the release centre for channel status, distributed only as the standalone Full APK; the Google Play line was discontinued on 2026-11-10. Requires Android 9 (API 28) or later on an ARM64 device. Tasks use your own cloud model configuration; there is no on-device model inference.

<!-- doc-anchor: section-1 -->
# Floe for Android User Guide

[简体中文](ANDROID_GUIDE.zh-CN.md) · [Documentation](README.md) · [Release centre](https://www.floe-agent.com/en/releases?platform=android) · [GitHub Releases](https://github.com/JiangNanGenius/floe-agent/releases)

Floe for Android turns your phone into a lightweight agent workbench: cloud-model tasks, project files, device control, a project-scoped ARM64 Linux terminal and graphical applications, network tools and scheduled tasks. This guide follows the actual published interface and wording; menu labels may differ slightly between versions — trust the interface of the build you installed.

## Contents

**Getting started**

- [1. Install and update](#1-install-and-update)
- [2. Your first cloud model and task](#2-your-first-cloud-model-and-task)
- [3. Self-ADB: embedded ADB access](#3-self-adb-embedded-adb-access)
- [4. Root access (optional)](#4-root-access-optional)
- [5. Device control (Accessibility)](#5-phone-control-accessibility)

**Workspace and tools**

- [6. Project Linux: terminal and graphical session](#6-project-linux-terminal-and-graphical-session)
- [7. Files and external editors](#7-files-and-external-editors)
- [8. Network tools (More → Network)](#8-network-tools-more--network)
- [9. Scheduled and condition tasks](#9-scheduled-and-condition-tasks)
- [10. Voice, memories and skills](#10-voice-memories-and-skills)
- [11. Version, diagnostics and feedback](#11-version-diagnostics-and-feedback)
- [12. Current limitations](#12-current-limitations)

## 1. Install and update

### 1.1 Install

1. Download the latest Android Full APK (application ID `com.floe.agent.full`) from the [release centre](https://www.floe-agent.com/en/releases?platform=android) or [GitHub Releases](https://github.com/JiangNanGenius/floe-agent/releases).
2. Open the APK to install. Installing over an existing copy keeps your tasks, projects and files; no uninstall is needed.
3. On first use, Floe prompts you to install the **Linux runtime component** (a companion APK from the same release). Confirm it in the system installer. The component matches the main app version one-to-one — always use both packages from the same release.

### 1.2 In-app updates

Open **Settings → Diagnostics & About → App update**:

- The **Check for updates automatically** switch controls automatic discovery; you can also tap **Check for updates** at any time.
- The **download source** can be official GitHub or third-party mirrors (GHFast, GH-Proxy). Package verification stays enabled with mirrors; a failed verification discards the download.
- When your installed build exactly matches the delta patch's base version, the smaller **delta patch** is preferred. If the delta is unavailable or fails verification, Floe falls back to the full package, and you can always **Download full update**.
- Installing requires your confirmation in the system dialog. When the Linux runtime component is updated too, Android may ask for a second confirmation — confirm each prompt in turn. Installing closes the app; save your work first.

### 1.3 Upgrading old clients

If the in-app update fails on a very old client, download the latest full APK from the release page and install it over the existing copy once. No uninstall is needed and your data is kept.

## 2. Your first cloud model and task

See [Models, tasks and files (shared)](SHARED_GUIDE.md) for provider setup, useful instructions, checking results and feedback. The steps below cover the Android menus and workflow.

Floe for Android has no on-device model inference; tasks use the cloud model service you configure.

### 2.1 Configure a model provider

1. Open **Settings → Model & Provider**.
2. Tap **Add Provider** and choose a purpose first (chat model / image generation and editing / video generation).
3. Fill in the supplier, protocol, base URL and API key. The API key is stored only in this device's secure storage. Plain HTTP is allowed only for localhost or private-network addresses, behind its own explicit option.
4. Tap **Test Connection**, then use **Manage Models** to add or refresh the model list.
5. **Model Routing** (entry on the same settings page) assigns the primary, auxiliary, vision and other roles separately; unset roles inherit the defaults.

### 2.2 Run your first task

1. On the home screen (New Task), type your instruction, for example “Summarize chapter 3 of the PDF in my workspace”.
2. Choose a configured model from the **Model** control in the composer.
3. Send. Floe works through a plan; tool calls follow the task's own grants, and you can review each step's output.

## 3. Self-ADB: embedded ADB access

**Embedded ADB access** is Floe's own on-device shell-level service: it gives Floe shell-level file and system operation capabilities **on this same phone**. It is not root, not the Shizuku app, and not a way for a computer to manage the phone remotely; the service is owned and used by the Floe app itself.

First, keep the three different kinds of access apart and enable only what you need:

| Capability | Entry | What it does |
| --- | --- | --- |
| Device control (Accessibility) | Settings → Device → Device control (Accessibility) | Observes and operates the apps you select (see §5) |
| Embedded ADB access | Settings → Device → Embedded ADB access | Shell-level files, read-only system folders, app management (this section) |
| Root access | Settings → Device → Root access | Highest-privilege operations with an existing root grant (see §4) |

Merely “connecting adb from a computer” gives Floe no capability at all. You must complete the pairing or bootstrap below so that Floe's own service is running.

Once embedded ADB is on, you can configure as needed:

- **Shared folders for system access**: Downloads, Documents, Pictures, Camera (DCIM), Music, Movies; changes can be allowed or refused per selection. With **Allow changes in the selected folders** off, these folders are read-only.
- **System folders (read-only)**: System, Vendor, Product, System extension, ODM, APEX. These are inspection-only; Floe never remounts or modifies the system.
- **App management**: lets an approved task force-stop a package through the running system service. Floe itself is always refused.
- **Other app data (Root only)**: add one app's data folder as an absolute path; available only while Root is running.

### 3.1 Android 11 and later: wireless pairing

Android 11+ uses the system's Wireless debugging for pairing — everything happens on the phone, no computer needed:

1. Open **Settings → Device → Embedded ADB access**, turn on **Embedded ADB**, and tap **Pair with Android**. Floe opens the system's Developer options.
2. Turn on **Wireless debugging** in system settings, then tap **Pair device with pairing code**. The screen shows a 6-digit pairing code and a **pairing port**. The pairing port is used only for this pairing step — it is not the port the service connects through later.
3. Enter the 6-digit code in Floe's **pairing notification** (keeping Android's pairing screen in front). If notifications are off, follow the prompt to allow pairing notifications; you can also use split screen and enter the code directly in Floe. Floe looks up this device's pairing port automatically; if it cannot, enter the port manually as prompted.
4. After pairing succeeds, return to Floe and tap **Start service**. Floe connects to this same phone's debugging service through the loopback address (127.0.0.1) at the **current actual connection port** — the port shown as “IP address & Port” on the Wireless debugging main page, which differs from the pairing port. The status shows **Service running** with the shell identity (UID 2000) when it succeeds.

Notes:

- **There is no fixed port**: after toggling Wireless debugging off/on or changing Wi-Fi, the connection port may change. Floe always reconnects using the current actual port; if automatic discovery is unavailable, follow the on-screen prompt and use the port currently shown on the Wireless debugging page.
- **After a phone restart**: the pairing trust is kept, but you need to turn Wireless debugging on and **Start service** again.
- If Floe asks for local network access, allow it; otherwise it cannot find this device's pairing port.

### 3.2 Android 9/10: one-time USB setup from a computer

Android 9/10 have no system wireless pairing, so a computer performs a one-time USB bootstrap. The point is to **let Floe reach its own embedded service on this same phone** — the computer does not become the phone's manager:

1. Install [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) on the computer (see the official [Android Debug Bridge documentation](https://developer.android.com/tools/adb)).
2. Enable **Developer options** and **USB debugging** on the phone, connect it over USB, and allow this computer's debugging authorization on the phone.
3. On the phone, open **Settings → Device → Embedded ADB access**, turn on **Embedded ADB**, then tap **Copy USB setup command**. The command is copied to the clipboard.
4. First make sure the computer sees the phone. Run in a terminal:

   ```bash
   adb devices
   ```

   Normally the list shows only this phone with state `device`. If it shows `unauthorized`, allow this computer's debugging authorization on the phone and retry. If it shows `offline`, reconnect the USB cable or toggle USB debugging. If several devices are listed, disconnect the others first, or replace the leading `adb` in the command with `adb -s <serial>` in the next step (the serial is the first column for that device in the list).
5. Paste the copied command and run it once in a POSIX shell on the computer (the macOS/Linux terminal; on Windows use a POSIX environment such as Git Bash, and make sure `adb` is on that shell's PATH).
6. The command starts Floe's own system service (as the shell user) through the phone's adb session. Back on the phone, Floe shows **Service running** (shell identity UID 2000) when it succeeds.

About this command:

- It is **generated dynamically for the currently installed version and a one-time handshake**, bound to this Floe installation on your phone; do not save and reuse it as a fixed script. After a phone restart or service stop, tap **Copy USB setup command** again for a command matching the current state, and run it from the computer once more.
- It does **not** open a TCP debugging port such as 5555 on the phone. Some older tutorials use `adb tcpip 5555` to keep a TCP daemon open — that is not Floe's flow, and Floe does not need it. Only keep such a daemon open on a trusted network when you actually need it; if you ever enabled it from such a tutorial, return to USB mode with `adb usb` on the computer, or turn off USB debugging / restart the phone to end it.

### 3.3 Verify, revoke and troubleshoot

- **Verify**: Settings → Device → Embedded ADB access. **Service running** means the service is live.
- **Pause**: tap **Stop service**. **Forget pairing** removes the saved pairing and stops the Floe service first (other apps are unaffected). Turning off the **Embedded ADB** switch disables the whole feature.
- **After a restart**: on Android 11+, turn Wireless debugging on and start the service again; on Android 9/10, run the USB setup command from the computer once more.
- **Common prompts**: if Wireless debugging is not found, make sure it is enabled in Developer options, then start the service again. If the pairing code is not accepted, check the current code on Android's pairing screen and retry. If pairing was removed in Android settings, pair again to restore access.

## 4. Root access (optional)

Root access is **off by default** and uses a root grant this device **already has**. Floe never roots a phone and never promotes ADB to root.

1. Open **Settings → Device → Root access**.
2. Tap **Check root grant** and confirm the prompt to use the device's existing root grant. A successful check can enable root access; otherwise Floe reports that no grant was found.
3. Once enabled, only operations you start run as root, and you can turn it off again at any time.

Embedded ADB and Root have at most one active backend: when Root owns the transport, a live ADB service reports as paired standby, and vice versa.

<!-- doc-anchor: 5-phone-control-accessibility -->
## 5. Device control (Accessibility)

Device control lets a task observe screens and act **inside the apps you select**, using Android's Accessibility service.

### 5.1 Enable it and choose apps

1. Open **Settings → Device → Device control (Accessibility)** and tap **Open Accessibility settings** to enable Floe's phone-control service. If Android blocks it, follow the prompt to allow restricted settings in App info, then enable the service again.
2. Under **Apps the Agent may control**, tap **Choose apps**: only the apps you select can be observed or controlled. There is no all-apps grant; switching to a different foreground app is refused.
3. Under **Screen content**, choose when the active task may see the screen: **Off / This task / Until stopped**. Nothing is recorded continuously; a screenshot is captured only when the task asks for the observed page.

### 5.2 Use in a task, take over, stop

- Each task must explicitly **allow device control for this task**; the Agent cannot arm it itself.
- While running, the task shows its state (Running / Waiting for you / Taken over / Stopping); you can **Take over** or **Stop** at any time. Taking over blocks new actions and leaves the task for your review.
- While you are using the phone, execution pauses and waits for your confirmation.
- Boundaries: only the visible page of the active task is observed; actions are read back after they run and gestures are not replayed blindly; secure windows and the lock screen stay protected by the system.

### 5.3 Unlock for tasks (known password)

If you choose, a task can enter your saved device PIN or password locally to unlock the phone:

- Turn on **Unlock for tasks** in settings and **agree and save on this device**. The credential never goes to the model or to diagnostic reports.
- A failed attempt stops and waits for you; it is not retried in a loop. The phone locks again only if the task unlocked it and you have not taken over.
- **Pattern locks and some system screens need manual help.** Automatic unlock behavior varies by device and lock type; the full observe → act → finish → relock chain is still being verified on real devices. If it fails, follow the prompt and take over manually.

## 6. Project Linux: terminal and graphical session

### 6.1 Install the local environment

1. Open **Settings → Execution environment → Local environment** and follow the prompts to download and install the Linux environment. The Linux runtime component from §1.1 must be installed first.
2. When it shows **Environment installed**, terminal tasks are ready. If it reports unavailable, open a terminal in a task once or tap **Recheck** as prompted (this only re-measures; nothing is reinstalled or downloaded).

### 6.2 Task terminal

- In a task's inspector (Terminal tab), open a new tab to run commands in that task's Linux environment; multiple tabs are supported.
- Model command-line work happens in the terminal first; file changes from a terminal session appear in Workspace Files when the session ends.

### 6.3 Graphical session (Linux applications)

1. In a task's **Workspace Files** page, tap **More → Linux applications** in the title bar.
2. Install the basic graphical components once when prompted; then choose **Single app** or **Desktop** mode and tap **Start session**.
3. You can **Open selected file**, **Choose an application**, or install new software; **Return to application** switches between the session and Floe.
4. Closing the window leaves the session running. **Stop session** closes the Linux applications and returns saved files — save your changes inside them first.

## 7. Files and external editors

### 7.1 Workspace files

A task's Workspace Files page offers: New file/folder, file actions (move and more), Source (Git), **Network storage** (WebDAV/SMB server connections, copy from and send to servers), recovery copies and live preview. Office documents open for offline preview and editing directly in Floe; CAD/3D files can be previewed on-device.

Office and CAD previews use **optional preview components**: install one when you first open such a file, or from **Settings → Data management → Optional preview components**. Each component is downloaded from the release channel, verified, and confirmed by the system installer; it is stored separately from your documents, and removing it never affects them. After an app update, the CAD preview component may need to be downloaded once more.

### 7.2 Edit in another app

Light text, Markdown and code editing happens directly in Floe by default; for professional editing, hand the file to another Android app:

1. In **Workspace Files**, tap **More → Edit in another app** and choose the project file.
2. Choose an editor: the system default app opens directly when one exists, otherwise the system chooser appears; **Choose another app** picks a specific one.
3. Save in the other app and the changes **return to the project automatically**; back in Floe you can **View original version** to compare.
4. If the original file also changed, both versions are kept — choose **Keep current file** or **Use edited copy**; tap **End editing** when done to release the file.

If no suitable Android app is installed, edit with a Linux graphical application from §6.3 instead.

## 8. Network tools (More → Network)

The network workbench lives under **More → Network** in the sidebar (also **Settings → System capabilities → Network diagnostics**). Every measurement runs only after you tap **Start**, and results stay on the device. On first use, allow the requested network/local-network permission and start the check again.

- **Wi-Fi / Overview**: current connection, signal, channels and access-point distribution.
- **DNS lookup / Ping / Traceroute / TCP connection / HTTPS request**: single checks against a host or address you enter.
- **LAN discovery**: find devices that advertise services, or scan an explicit private IPv4 subnet (RFC1918 /24–/30). mDNS service discovery needs Android 13 or later; on Android 9–12L the subnet scan still works. Nothing is swept automatically.
- **Speed test**: measures download, upload or both against an HTTPS endpoint you control; each direction has a fixed data (1–32 MiB) and time (1–15 s) budget, and redirects are not followed. A metered network is refused unless you explicitly allow it.
- **Monitoring**: connection status, Ping or TCP at 5–300 s intervals for 1–60 minutes; a foreground notification offers **Stop**; at most 720 checks are kept. Monitoring continues while Floe is in the background but never restarts by itself.
- **Captures & coverage**: rootless VPN capture runs on the phone without root (it does not decrypt TLS traffic); with embedded ADB or Root, the Full build also offers genuine native packet capture.

## 9. Scheduled and condition tasks

Open **Scheduled tasks** from the **Task Center** (or the scheduled-tasks card on Home):

- **New scheduled task**: a title and task instruction, then a repeat mode: **Once / Daily / Weekly / Interval / After success** (runs after a chosen task succeeds) / **When charging starts** / **When internet connects**.
- Choose the workspace (a new independent workspace per run, or an existing project workspace), model, environment and approval mode (Ask each time / Automatic / Full access).
- **Exact time**: tasks that must run on time use exact alarms; without that permission, choose **Use flexible schedule** if running a little late is acceptable.
- **Background running**: scheduled tasks need notifications allowed to stay protected in the background. Battery settings decide whether Android lets a scheduled task start on its own (the settings offer **App battery settings** and **Battery optimization list** entries). If the system blocked a start, open Floe and retry.
- **Run history** shows each recorded run; open the task from history or from a notification.

## 10. Voice, memories and skills

- **Voice** (Settings → General): speech input, read aloud and media transcription. Input and output can use the **System** or **Cloud** engine; media transcription uses your configured cloud provider model.
- **Memories & Personalization**: manage what Floe remembers, organize suggestions and personalization revision history.
- **Skills & Connectors**: manage skills and connectors; **Web Search** configures the search provider.
- **Usage**: token usage by day, model and provider.

## 11. Version, diagnostics and feedback

- **Check your version**: Settings → Diagnostics & About. The page shows the version, distribution (Full), shared-core status and local-task-execution diagnostics with **Retry**; in-app updates live here too (see §1.2).
- **Diagnostics and feedback** (Settings → Diagnostics & About): describe the problem, optionally attach up to four screenshots (resized and compressed before upload; originals stay unchanged) and basic diagnostics, or turn on **Automatically report App faults**. Reports upload on Wi-Fi unless you allow other networks; failed reports are kept on the device and can be retried. Feedback is optional diagnostic material with **no individual reply guarantee**.
- **Report actual bugs**: file them on [GitHub Issues](https://github.com/JiangNanGenius/floe-agent/issues) with the version (shown on the Diagnostics & About page), device model, Android version and reproduction steps.

## 12. Current limitations

- **Full APK only**: the Google Play line was discontinued on 2026-11-10 and no Play build is provided.
- **No on-device model inference**: tasks depend on your own cloud model configuration; without a configured model, tasks cannot run.
- **Embedded ADB on Android 9/10** needs the computer USB setup for every service start; system wireless pairing exists only on Android 11+. Physical-device verification on Android 9 is still in progress; individual devices may hit issues — please report them via feedback or GitHub Issues.
- **Automatic unlock** is limited by device and lock type (see §5.3); pattern locks and some system screens need manual help.
- **Feature parity with iOS is not claimed**: for example, CAD/3D on Android is an on-demand preview viewer, not the native 3D modeling editor of iOS. Check each version's [release notes](https://www.floe-agent.com/en/releases?platform=android) for what it actually ships.
