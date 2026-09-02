# Creative Mode, Canvas, and Artifact Architecture

[简体中文](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.zh-CN.md) · [User guide](USER_GUIDE.md) · [Architecture overview](ARCHITECTURE_OVERVIEW.md)

## Canvas workflow

Floe uses one persisted canvas graph and three product roles:

1. **Content nodes** hold ideas, notes, prompts, and explicit references. An unconnected text node remains a note; once connected, it becomes bounded context for downstream work.
2. **Task nodes** hold provider-neutral generation configuration and execution state. Saving configuration never contacts a provider.
3. **Artifact nodes** hold imported or generated files. Imports come from Files, Photos, or the shared material library. Generated artifacts remain connected to their task.

The generation state machine is `needsConfiguration → configured → preparing/uploading → submitted/running → completed/downloading → ready`, with `failed`, `cancelled`, and `expired` recovery states. A task card exposes one contextual primary action: Configure, Start, Cancel, Retry, or Generate Again. Retry reuses the original task and artifact nodes.

## Node AI and Canvas Assistant

The compact AI field below a selected node is a node-scoped editor. It receives only the node's latest value, saved compatible configuration, explicit reference nodes, and the current instruction. It returns a structured patch, applies that patch through the existing undo/save/sync mutation path, and never creates a Conversation or Run, opens Canvas Assistant, invokes tools, or starts generation. A bounded edit summary is retained for recovery and audit; hidden model reasoning is never displayed.

Canvas Assistant is the separate cross-node research and orchestration surface. It uses the normal Conversation/Run/checkpoint system and a canvas-filtered tool catalog. A text-only primary model receives a bounded description from the configured Canvas Vision model when selected image context is present. Missing visual capability and deterministic provider/tool errors fail once with an actionable message. Transient network or server errors receive at most one retry on canvas, and the first unchanged tool-result retry ends that route.

## Direct manipulation

- Drag empty space with one finger to pan; drag a node to move it.
- Two fingers pan and zoom together without changing tools; Apple Pencil draws.
- Double-tap empty space to create, editable content to edit, or a task to configure.
- Connection ports keep a 44-point hit target around a smaller visual control. Dragging shows a curved preview, target magnetism, valid-target highlighting, and haptic confirmation. Dropping on empty space opens the shared creation menu and connects the new node.
- Directed generation edges use arrows; weaker reference edges use dashed curves.

Canvas onboarding is versioned per device, independent of global app onboarding, and can be replayed from the canvas More menu.

## Compatibility and persistence

`CanvasGenerationConfiguration` and `CanvasGenerationTaskState` are encoded into the existing node metadata fields. Older canvases continue to decode through legacy state and configuration aliases. All node edits, task transitions, connections, artifacts, undo records, persistence, and sync remain in the existing Canvas Store and media-generation services; there is no parallel canvas or generation database.
