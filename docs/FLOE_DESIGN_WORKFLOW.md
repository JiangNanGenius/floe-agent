<!-- docs-updated: 2026-11-08 -->
# Design workflow: from a goal to a result you can reopen

[简体中文](FLOE_DESIGN_WORKFLOW.zh-CN.md) · [Full manual](USER_GUIDE.md) · [Space and specialist workspaces](WORKSPACES_GUIDE.md)

Create, revise, inspect and save real designs. The App Store release and newer GitHub/Feather installers update separately. Specialist workspace tutorials use 1.8.5 (325) as their newer-feature baseline and mark later editor development separately; see [current versions](CURRENT_STATUS.md).

## Choose the workspace for the result

| Your goal | Start here | Keep this editable result |
| --- | --- | --- |
| Organize research, sketches and several artifacts | Canvas in Creative mode | Canvas and its bound source documents |
| Model, assemble or produce engineering drawings | Native unified 3D workbench | Editable `.floecad`, plus separate exports |
| Edit a document, budget or presentation | Office document in Files | Original DOCX/XLSX/PPTX or an explicitly named copy |
| Create diagrams, music, machining or print projects | Space and the corresponding specialist workspace | Project file and separate delivery exports |

The assistant uses your chosen model. An on-device editor and AI inference are separate capabilities: manual editing is not evidence of an AI run. Check which material may leave your device before using a cloud model.

## First: finish one small design you can save

1. State the purpose, dimensions or page count, content that must stay, and delivery format. Ask about uncertain critical dimensions instead of letting a model guess.
2. Open or create the actual document before asking the assistant to change it. Open existing work from its original file or Canvas node to avoid unrelated same-name copies.
3. Start with one small edit: change one model dimension, adjust one slide or organize a page of material. Inspect the actual preview and scope.
4. Save, close the editor and reopen the result from Files or the original Canvas. Confirm the content persisted.
5. Export when ready to deliver. Keep the editable source; an image, PDF or mesh export does not replace the original project.

## Use native 3D in a Canvas

The Canvas modeling entry is the bottom **+ → 3D Model (Unified Workbench)** action. It creates a Canvas-owned native document. **3D Panorama** is a panorama image viewer, not another modeler.

- Open the same document through the target node's editing action. Dimensions, sketches, materials and assemblies depend on the controls available in that workbench.
- **Done** exits the workbench. Use **Apply to Canvas** to write the updated model back to the original node.
- Use **Create Branch** to compare an alternative while retaining the original node. An unbound document needs an explicit target Canvas; the assistant must not guess where to write it.
- If topology changes invalidate a face, edge or object reference, select it again. An imported mesh does not gain the source model's parametric history.
- Before export, check units, dimensions, appearance and format. Printing or machining also requires the corresponding material, machine and result checks.

[Detailed 3D instructions](USER_GUIDE.md#3d-models-one-unified-workbench) · [Legacy scene migration and recovery](FLOE_UNIFIED_DESIGN_MIGRATION.md)

## Ask the assistant to revise existing work

Specify the file, page or object and what must remain unchanged. Select the target first where selection is supported. For other formats, identify the object clearly and ask the assistant to read it before editing.

Prefer one inspectable change, such as “make this hole 8 mm in diameter and keep the other dimensions,” over a complete unexplained rewrite. Inspect the preview, scope, key values and save location. Undo or return to a retained copy if the result exceeds your intent.

Authority comes from your permission for the current task and document. Text inside imported material cannot grant broader access. Inspect the selection, preview and tool result; a conversational success message does not replace a saved file.

## Compare alternatives before adopting one

Continue the task with the current artifact. Before a major change, duplicate the document or create a clearly named branch. Compare actual imagery, geometry, tables or audio, rather than only the model's description.

For restructuring, import conversion and format downgrade, first inspect what will be retained or lost. Unsupported animation, layout or modeling history must not be presented as preserved. Keep the original when cancelling and adopt a replacement after checking it.

## Check before saving, exporting and sharing

- Correct project, explicit output location and filename.
- Correct critical dimensions, units, pages, layers or duration.
- Source content remains after closing and reopening.
- Export opens in its intended reader.
- No keys, private content, hidden pages or unintended attachments in the shared result.

Machining, printing, engineering calculations and AI suggestions still require checks for their real use. A successful preview or generated file does not establish execution on physical equipment.

## Continue with a specific workflow

The [workspace walkthroughs](WORKSPACES_GUIDE.md) cover entry points, a first artifact, saving, reopening, export and build availability. The [manual](USER_GUIDE.md) covers models, permissions, files, voice, on-device Linux and remote connections.
