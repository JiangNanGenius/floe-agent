<!-- docs-updated: 2026-11-10 -->
# From installation to your first result

This guide focuses on iOS / iPadOS and calls out Android differences. Check the selected release for its actual capabilities.

## Choose an installation channel

Open the [release centre](https://www.floe-agent.com/en/releases) and choose Floe Agent, Mac Bridge or iOS Bridge. Floe Agent is available on the App Store for iOS/iPadOS 26+; update through the store. GitHub iOS IPAs require your own signing and may carry newer features. Check [channel versions and verification dates](CURRENT_STATUS.md) before choosing an installer. [Apply on the website](https://www.floe-agent.com/en#beta) for TestFlight access; applying does not guarantee immediate eligibility.

On Android, download the signed APK for the selected public alpha. A complete current APK does not require installing every intermediate version. A delta needs its exact stated base. If Android reports a different signer, preserve your data rather than uninstalling just to proceed.

## Complete an AI task

**Prepare:** a working provider configuration and API key. Choose an image-capable model when the task needs to read pictures. Your chosen provider handles cloud requests under its own pricing and data policies.

1. Add the provider, endpoint, key and model in settings. Confirm a simple text conversation works.
2. Create a task and select its workspace. Add a non-sensitive test file through the file picker.
3. Request a concrete result, for example: “Turn this material into a checklist and save it in this workspace.” Grant access to the relevant files and tools as needed.
4. Open the output and check its content, location and format. Close and reopen it to confirm it was saved.

**If it fails:** check the key and endpoint for authentication errors, use an image-capable model for images, and reselect the original workspace for file-access problems. A tool success message alone does not prove the result was saved correctly.

## Run code on your device

**Prepare:** enough storage and memory. Current iOS uses a shared ARM64 Linux runtime while retaining task and project ownership. Packages must match the guest architecture.

1. Download and verify resources in execution-environment settings, then open the current workspace terminal.
2. Run `pwd` and `uname -m` to check the directory and actual architecture. Install Python, Node.js or other required packages for that environment.
3. Run a small program and open its output. For an HTTP service, choose **Run as web service**, wait for a real response, then preview it.
4. Stop the owning job or service when finished. Hiding the terminal or closing the preview does not stop background work.

**If it fails:** inspect installation, startup and job output first. On the current Android alpha, if the terminal stops starting after an upgrade, update runtime components separately under Settings → Execution → Local Environment. Preserve project files before repair; do not reset or delete data as a first step. See [terminals and environments](USER_GUIDE.md#9-local-terminal-and-linux-performance).

## Create and save a 3D model

**Prepare:** an iOS/iPadOS release with the native 3D workbench. Imported meshes do not gain native parametric history, and supported operations vary by format.

1. Create a native 3D model through the creative workflow, beginning with simple geometry.
2. Refine dimensions, holes or fillets in the same model. When using the assistant, identify the current model and the intended change.
3. Check geometry, materials and views; save the `.floecad` file and reopen it.
4. Export an image or supported 3D format for the intended use, then check it in the receiving tool.

**If it fails:** preserve read-only imports rather than treating successful import as editable support. Undo a failed geometry change to a recoverable state. See the [native 3D manual](USER_GUIDE.md#3d-models-one-unified-workbench).

## Try a work in Space (newer builds)

**Prepare:** an installer that includes Space; see the [workspace guide](WORKSPACES_GUIDE.md) for the required build and [channel status](CURRENT_STATUS.md) for availability. GitHub IPAs need your own signing.

1. Open **Space** from the sidebar and switch to Files. Tap **New** and create a drawing or a document; name it.
2. Edit the work, then close it and reopen it from Continue working to confirm it saved.
3. Open the work's assistant and ask it to summarize or continue the work; review any proposal before accepting it.
4. Delete the test work and restore it from Recently Deleted to learn recovery.

**If it fails:** confirm the build supports Space (Settings → Diagnostics & About). See [Space and specialist workbenches](WORKSPACES_GUIDE.md) for meetings, music, printing and the toolbox.

## Choose the right Bridge

| Product | Purpose | Before connecting |
| --- | --- | --- |
| Floe Bridge · Mac | Terminal, files and MCP for Floe on the same Mac | Both apps run on one Mac and confirm the same pairing code; this is not an iPad-to-Mac remote bridge |
| Floe iOS Bridge | A standalone local automation bridge for iPhone and iPad | Required signing capabilities, device preparation and pairing; version 1.0 does not integrate with the main Floe app |

Mac Bridge: install a [selected release](https://www.floe-agent.com/en/releases?platform=bridge), open the menu-bar app, and connect from Floe on the same Mac. Compare the code and approve both prompts. Check the directory and read a test file before starting work. Commands are not replayed after disconnection. If the menu-bar icon is missing, relaunch the app; if pairing fails, check both versions and confirmations.

iOS Bridge: start with the [versioned installation instructions](https://github.com/JiangNanGenius/floe-agent/blob/floe-ios-bridge-v1.0.0/FloeIOSBridge/INSTALL.md). Version 1.0 requires signing with Network Extension capabilities; arbitrary re-signing setups are not guaranteed. Complete preparation in the app and approve client pairing on the device. Access is local by default; enable LAN access only when needed. Read the screen after an action; do not automatically repeat a tap when its result is unconfirmed.

## Save, recover and get help

Confirm saving in each Office, media or 3D editor. Save-as and export do not automatically replace the original. After Android external-editor or Linux edits, wait for writeback before reopening; preserve recovery copies when conflicts remain. Keep independent backups of important files.

For support, describe the version, device, steps, expected result and actual result in the [support channel](https://github.com/JiangNanGenius/floe-agent/blob/main/SUPPORT.md). Submit only necessary diagnostics or screenshots voluntarily; never include passwords, keys or private files. Continue with the [full manual](USER_GUIDE.md) and the [workspace guide](WORKSPACES_GUIDE.md).
