# Floe Agent Design Direction

## Locked direction: Threaded Operations Desk

The Alpha adopts a **Threaded Operations Desk**: a native iOS workspace where every agent task is a durable thread and every consequential action leaves inspectable evidence. It combines Manus-like visible task progression with Codex-like execution clarity, while retaining Floe's own identity through flowing state markers, restrained cyan-blue-violet accents, and calm language.

This direction was selected from seven grounded alternatives because it best serves the product's defining combination of chat, approvals, Files, SSH, and VNC. It is not permission to visually clone either reference product.

## Information architecture

- Normal cold launch and every newly created scene open directly into **New Task**. Returning from the background preserves the current task; notifications and Live Activities deep-link to their task.
- The primary sidebar contains **New Task**, **Task Center**, **Skills**, expandable project workspaces, a **Chats** group for private tasks, and account/settings at the bottom.
- Providers, auxiliary models, memory, permissions, privacy/data controls, and diagnostics live inside Settings and never duplicate in the primary sidebar.
- The center column contains exactly one new-task draft or one continuous task thread.
- The right inspector is collapsed by default and exposes Changes, Files, Browser, Terminal/Host, Progress, Child Agents, and Permissions for the selected task.
- iPhone projects the same workbench selection into a drawer, navigation stack, and inspector sheet/full-screen browser instead of maintaining a separate business state.
- The execution thread is the canonical representation of assistant output, tool steps, terminal results, approvals, errors, checkpoints, questions and evidence.

## Visual system

- Use system typography with clear title, section, body, metadata and monospaced evidence roles.
- Use the brand cyan-blue-violet only for selection, progress and the primary action.
- Reserve amber for pending decisions, red for destructive actions or failure, and green for confirmed success.
- Use Liquid Glass/material only for navigation chrome, the composer and floating actions. Reading surfaces remain opaque.
- Prefer whitespace, dividers and grouping over nested card stacks.
- Use SF Symbols in the production UI. The generated reference images are composition and atmosphere references, not pixel specifications.
- Support light/dark appearance, Dynamic Type, VoiceOver, Increased Contrast and Reduce Motion from the first implementation.
- Never communicate status by color alone; interactive targets are at least 44 × 44 points.

## Interaction principles

1. A screen must answer: What is happening? What happens next? Does the user need to decide? Where is the evidence?
2. Approval surfaces show the exact scope, host, command/tool, risk reason and expiry before action.
3. Stop is always reachable during a run or remote session and is visually distinct from ordinary actions.
4. Disconnected, suspended and unknown states are represented honestly and cannot look like success.
5. iPad keyboard and pointer behavior is first-class; iPhone retains complete functionality without becoming a compressed desktop UI.

## Reference assets

- `docs/design/reference/floe-alpha-iphone-home.png`
- `docs/design/reference/floe-alpha-ipad-workbench.png`
- `FloeAgent/FloeApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`

Both generated Alpha references are historical explorations and do not define the 1.2.0 navigation. The current workbench screenshot in `docs/images/floe-agent-new-task-ipad.webp` is the closest checked-in visual evidence; implementation remains the source of truth.
