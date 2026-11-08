<!-- docs-updated: 2026-11-08 -->
# Storage, cleanup and diagnostic reports

[简体中文](FLOE_STORAGE_DIAGNOSTICS.zh-CN.md) · [Manual](USER_GUIDE.md) · [Current versions](CURRENT_STATUS.md)

Inspect Floe's own data, reclaim space and provide useful fault reports. Available controls vary by installed build; see the [specialist workspace tutorials](WORKSPACES_GUIDE.md) for newer projects.

## Read the right figures

Open **Settings → Data management** and let the current scan finish, or stop it if no longer needed. Distinguish the App itself, user data, shared files and the cleanup categories actually shown before inspecting large items. A partial scan is not the final total.

- **Logical size** is a file's apparent content length. Sparse disks, compression and clones can make actual storage different.
- **Allocated size** describes filesystem allocation, not necessarily the space that deleting a file will release. Shared blocks and system snapshots affect the result.
- Check the purpose and source of **Shared files** separately instead of treating their names as proof they are disposable.
- iOS **Settings → General → iPhone/iPad Storage** uses the system's accounting. Floe's figures are neither device-wide free space nor a replacement for those figures.

## Clean up in this order

1. Export important documents and projects, then open the copies. Keep editable sources for Canvas, Office, 3D, music, printing and other work.
2. Inspect the App's cache or download management actions and read what each action removes.
3. Before deleting tasks, environments or projects, confirm their jobs are stopped and their files are no longer needed. Notes is an independent library rather than part of a single chat; still check the exact selected item before deletion.
4. Removing models or environment images may require a later download. Consider network access and the next use before deleting them.
5. Rescan after cleanup. Estimated cleanup capacity and actual reclaimed space can differ; check system free space afterward.

Do not delete internal databases, environment directories or parts of project packages from a file manager while work is running or saving. Prefer the App's export, share and file-management actions when moving work.

## When files look duplicated

The same filename does not establish identical content. Versions, branches, exports and source projects may all be useful. Conversely, clones and hard links may look like separate files while sharing storage, so simply adding their sizes can overcount.

Open and identify the contents, location and editability first. A complete project and its PNG/PDF/mesh export cannot replace one another.

## The main route for bug reports

Use [GitHub Issues](https://github.com/JiangNanGenius/floe-agent/issues) for feature requests and faults. Include the goal, reproduction steps, expected and actual results, plus the version and build from **Settings → Diagnostics and About**. Record important issues there so they can be discussed.

In-App diagnostic upload only adds fault evidence; it is not a support ticket. Submission does not guarantee viewing, a reply or a response time. Inspect logs and screenshots before uploading and remove passwords, API keys, tokens and unnecessary personal content.

The upload endpoint checks client versions. If it requests an update, update as directed before retrying. If the App Store already shows the latest version but uploads are still refused, report the channel and version in a GitHub Issue rather than repeatedly uploading the same material.

## Screenshots and sharing

Choose screenshots that explain the fault and inspect visible filenames, accounts, chats and notifications. When sharing a project, check whether the export retains additional source material.

Diagnostic data, local projects and reports submitted to the website are managed separately. Deleting a local file does not delete a report already submitted to the website. A saved result or backup does not establish that model inference, cloud services and device behavior have all been verified.
