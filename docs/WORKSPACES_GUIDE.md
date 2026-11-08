<!-- docs-updated: 2026-11-08 -->
# Space and specialist workbenches

[简体中文](WORKSPACES_GUIDE.zh-CN.md) · [User manual](USER_GUIDE.md) · [Quickstart](QUICKSTART.md)

Task-based tutorials for Floe's personal library and dedicated workbenches: Space files and works, meetings, music, diagrams, manufacturing and 3D printing, the network toolbox, and chemistry projects. For models, tasks, Notes and Office basics, read the [user manual](USER_GUIDE.md) first.

## Which build do I need?

Floe's channels carry different feature sets. Each section below is labeled with the build it needs:

| Label | Where you get it | What it covers here |
| --- | --- | --- |
| **1.7.74** | [App Store](https://apps.apple.com/app/id6801209053), iOS/iPadOS 26+ | The stable public release. Only sections labeled 1.7.74 apply; Space and the specialist workbenches are not in this build yet. |
| **1.8.5** | [GitHub Releases](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.5) (unsigned IPA; sign it yourself) or internal TestFlight | The newer-feature baseline for Space, meetings, music, diagrams, manufacturing and printing, the toolbox, and chemistry. |
| **Next update** | Not in any public installer | LaTeX, maps/GIS, electronics/PCB, biology, font design and related assistants exist only in development builds. |

Find your installed version in Settings → Diagnostics & About. Per-channel availability is tracked in [release and installation status](CURRENT_STATUS.md); the [release centre](https://www.floe-agent.com/en/releases) lists every published build.

## 1. Space: your files and works — **1.8.5**

Space is the sidebar home for everything you personally own in Floe: the Notes library plus a library of editable works and files.

**First walkthrough:**

1. Open **Space** from the sidebar. It has four sections: Overview, Notes, Files and Toolbox.
2. Overview shows quick-access entries, pinned works, your folders, and Continue working (recently opened notes and works).
3. Files lists your works. Switch between list and thumbnails, and filter by type: documents, drawing/images, video, or CAD.
4. Tap **New** to create a document (Word/Excel/PowerPoint/plain text or a Floe note), a drawing/image work, a video work, a 2D or 3D CAD design, or a chemistry project. Give it a name and it appears in Files immediately.
5. Use import to bring in existing files, or **Browse other locations…** to reach all workspace files, archived chat files and kept (recovered) documents. Deleted works can be restored from **Recently Deleted**.

**Ownership and saving:**

- Works are stored in your personal on-device library. They do not belong to any chat task: deleting a chat never deletes a work, and deleting a work never touches task or project files. Export anything important before deleting.
- Editors save into the work itself. Close and reopen a work from Continue working to confirm its latest state; recovery copies stay under Kept documents until you accept the saved file.
- A work can carry its own assistant conversation (Work assistant, or Meeting assistant for meetings). That conversation is part of the work and keeps unsent drafts; granting assistant access to one work does not open any other file.

## 2. Meetings: record, transcribe, minutes — **1.8.5**

Meetings combine a personal notebook, live recording, transcription and AI minutes in one work, opened from Notes.

**First meeting:**

1. In **Notes**, create **Meeting notes** (or open an existing meeting from Space). Each meeting is one work.
2. Start recording. Turn on **transcribe while recording** to see segments appear as you speak, or transcribe saved recordings and media later.
3. The inspector switches between **Transcript**, **Highlights** and **Meeting assistant**. Personal notes live on the notes page; minutes are organized separately and you insert what you want.
4. Turn on **automatic AI minutes** to keep minutes updated from the transcript, or ask the meeting assistant to answer questions about this meeting and organize notes and to-dos. Unsent drafts are kept.
5. Export **Word or PDF text minutes** from the minutes-template menu, and send follow-up actions back into your task flow.

**Limits:** recordings stay on device by default; cloud transcription uses a service you explicitly select and is billed by that provider. Transcription quality follows your recognition settings (see the user manual §16).

## 3. Music projects — **1.8.5**

Space music works keep arrangement, keyboard, mixer and DJ workflows in one project.

**First project:**

1. In Space → Files, create a **Music** work and name it.
2. The workbench offers arrangement plus dedicated surfaces: piano roll, drum grid, keyboard, and DJ decks, with a mixer and effects for tracks.
3. Import audio or MIDI material, or ask the assistant to propose edits; each proposal shows what changes before you accept it.
4. Save is automatic into the work. Render when you want an audio file, then check the receipt against the actual rendered file and share or export it from the work.

**Limits:** AI-assisted editing uses your configured models; playback and rendering run on device and follow the project's real capabilities.

## 4. Diagrams and the mixed canvas — **1.8.5**

Diagram works in Space hold structured diagrams with the same save/reopen behavior as other works. Creative mode's mixed canvas remains the free-form counterpart: text, images, assets and documents on one board, with the original editing framework — content, assets, history and undo — preserved. Both can be handed to the assistant within a task's permissions; adopt proposals only after reviewing the diff.

## 5. Manufacturing and 3D printing — **1.8.5**

Machining and printing open from a CAD document's **Manufacturing** entry.

**Machining walkthrough:**

1. Open your 2D/3D CAD design and enter Manufacturing. Choose the machine first.
2. Set stock, coordinates and operations; the assistant can read back the current object and suggest operations within the task's permissions.
3. Run the preview to watch material being removed along the toolpath; implemented collision checks are reported as they run.
4. Save the result, export STL or the toolpath, and reopen the saved result to verify. Manufacturing-cell (multi-spindle/multi-turret) programs save independently and can be read back later.

**3D printing walkthrough:**

1. From a CAD design or a file, prepare a print project; Floe copies the current geometry into it.
2. Arrange models on plates, add or duplicate parts, and adjust per-plate settings such as layer height and infill.
3. Pick a machine configuration: bed size, coordinate origin, nozzle offsets, custom start/end/tool-change G-code, and resin platform orientation for resin printers.
4. Slice; a completed slice opens Preview automatically, and the saved result stays bound to those parameters. Export the G-code your printer expects and check it in your slicer or host.

**Limits:** machining previews report implemented checks only — they are not a complete machine-safety certification. Native USB printer drivers are not included in this build; use your printer's normal transfer path. Physical printing and machining remain governed by your machine's real capabilities and safety rules.

## 6. Network toolbox — **1.8.5**

Space → Toolbox gathers network utilities that run on your device (the Android alpha ships a related workbench under More → Network).

- **Diagnostics:** ping, traceroute, DNS, port checks, LAN discovery, Wi-Fi information and roaming checks. Wi-Fi names and BSSIDs are read only with system authorization; nothing scans until you start it.
- **Connections and sessions:** HTTP, WebSocket and MQTT clients, a serial assistant (TCP, UDP or Bluetooth; USB needs a supported iPad and drivers not yet shipped), plus terminal and VNC remote workspaces.
- **Analysis:** capture browser with packet-capture import (PCAP/PCAPNG); AI analysis reports progress, can be stopped, and times out honestly.
- **Utilities:** JSON formatting, encoding conversion, QR codes and checksums.

A measurement covers one endpoint and path, not your whole network. Reports export only what you choose.

## 7. Chemistry projects — **1.8.5**

Create a **Chemistry project** from Space → New. The native structure editor saves structures into the project, calculation records stay attached to it, and structure images can be referenced from Notes. Heavy recalculation runs in your configured execution environment — check the environment before a long job.

## 8. Coming in the next update — **Next update** (not in public builds)

These workbenches are integrated in development builds and are not part of the App Store release or the 1.8.5 installer:

- **LaTeX projects** — source editing with the on-device engine (XeLaTeX workflow), compilation, PDF output and Notes handoff.
- **Maps/GIS** — GIS projects with layer editing and exports.
- **Electronics/PCB** — schematic and PCB editing projects.
- **Biology projects** — native editing with Notes structure references.
- **Font design** — AI-assisted font design beside the existing font management.
- Also in development: Apple Image Playground integration and music notation tools.

Expect these in a future release; check the [release notes](https://www.floe-agent.com/en/releases) for the build that ships them.

## Saving, exporting and help

- Confirm saves by closing and reopening the work; keep recovery copies until the accepted file checks out.
- Export or share before deleting; deleted works are recoverable from Recently Deleted only on the same device.
- Questions and bug reports: [GitHub Issues](https://github.com/JiangNanGenius/floe-agent/issues) (primary support channel); describe the build, device and steps. Diagnostics uploads are voluntary and carry no response-time guarantee — never include passwords, keys or private files.

[User manual](USER_GUIDE.md) · [Quickstart](QUICKSTART.md) · [Documentation index](README.md)
