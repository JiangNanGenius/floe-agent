# Floe Bridge

Floe Bridge is an optional same-Mac terminal companion for Floe running as an iPad app on Apple silicon. Normal Floe features remain available without it. The companion is distributed independently; a public download requires Developer ID signing and Apple notarization. Source implementation does not establish App Review approval or installability.

## Connection and execution

The user opens the installed companion and selects Connect in Floe. A native companion confirmation binds the client's Keychain public identity to the companion's public identity without typing a pairing code. Requests and responses are signed, responses are pinned, mutations have persisted replay admission, and the listener binds only to `127.0.0.1`. The connection is local, not a LAN terminal server. A user can revoke a paired identity in the companion. Screen Recording and Accessibility are requested individually when the user chooses the corresponding operation; they are never inherited by unrelated applications.

Only a task's trusted environment lease can select the `macBridge` backend. Model-supplied shell environment values cannot select host execution. New unbound tasks may prefer a connected Mac; an existing Linux binding stays Linux. A lost connection preserves the original job ID and reports an unknown outcome when execution could have started. Reconnect inspects that job; neither a transport retry nor choosing a backup reruns it. Backup selection applies to a new task.

Large shell commands use chunked, digest-verified private scripts instead of an oversized RPC frame or command-line argument. PTY output is saved in full and read in pages. The RPC/page bound is not a command size, execution duration or saved-output limit. Files are synchronized using hashes, atomic commits and concurrent-edit checks. Mac-created files return to the task workspace. Concurrent local and Mac edits require review; a remote deletion retains a recoverable local copy. The client reserves `.floe/terminal/` for full terminal output. The shared versioned transfer policy retains host dependency/cache directories (`node_modules`, `.venv`, `__pycache__`, `.build` and test/type-check caches) on the Mac; it still returns sources and user-facing products such as `dist`. It does not reimport host dependencies into the iOS container after every command.

## Storage and cleanup

| Directory | Ownership |
|---|---|
| `~/Library/Application Support/Floe Bridge/State/` | Pair public records, replay admission, version indices and recovery metadata. Private keys stay in Keychain. |
| `…/Workspaces/` | Managed workspace mirrors and explicitly staged install files. |
| `…/Tasks/` | Individual jobs, private command scripts, complete output and exit receipts. |
| `…/Skills/<id>/<version>-<digest>/` | Immutable original Skill files, separate from Linux adaptations. |
| `…/Environments/` | Managed host dependency/environment data. |
| `~/Library/Caches/Floe Bridge/` | Disposable transfers and download/package caches. |
| `~/Library/Logs/Floe Bridge/` | Operational diagnostics; never the task's full command output. |

The companion shows category sizes and Finder shortcuts. Cache/log cleanup moves only owned files to Trash; active transfers are protected. Specific completed task data and unused Skill versions can be cleaned through the authenticated management interface. A task with an unconfirmed exit and any pinned Skill version are retained. User folders, Homebrew, system tools, other models and Linux images are not cleanup targets. Deleting the app does not erase workspaces.

## Building and distributing

`FloeMacBridge/scripts/build_app.sh` creates a source-bound unsigned app from committed source. `notarize_app.sh` requires a Developer ID Application identity and an existing notary Keychain profile, then verifies signing, Apple acceptance, stapling and Gatekeeper assessment. Do not publish the unsigned app, notary responses or signing material. The Floe client exposes a download recommendation only after the release owner configures its real official notarized-download URL.

Required acceptance remains separate: Swift 6 object compilation, local pairing/revocation, native PTY and MCP exchange, workspace conflicts and artifact readback, unknown-start recovery, original Skill installation, App UI behavior, and notarized distribution.

First pairing requires matching a short fingerprint in both Floe and the companion's native confirmation. It is derived from both public keys plus a fresh pairing nonce; no code is typed. Floe pins the companion key only after the user confirms a match. A self-signed `paired=true` response cannot enable file or terminal traffic. Existing pairings only accept the previously pinned key. HTTP redirects are disabled, so signed command/input/file bytes never follow a redirect outside the fixed loopback endpoint.

File downloads use private staging and descriptor-relative `openat`/`O_NOFOLLOW`/`renameat` commits. The complete root chain and destination directory components are opened without following symbolic links at commit time; a directory replaced while a request is suspended cannot redirect the write.
