# Floe Agent Design Direction

## Locked direction: Threaded Operations Desk

The Alpha adopts a **Threaded Operations Desk**: a native iOS workspace where every agent task is a durable thread and every consequential action leaves inspectable evidence. It combines Manus-like visible task progression with Codex-like execution clarity, while retaining Floe's own identity through flowing state markers, restrained cyan-blue-violet accents, and calm language.

This direction was selected from seven grounded alternatives because it best serves the product's defining combination of chat, approvals, Files, SSH, and VNC. It is not permission to visually clone either reference product.

## Information architecture

- iPhone uses five top-level tabs: **Home, Chat, Files, Hosts, More**.
- iPad uses a three-column `NavigationSplitView`: functional sidebar, task/session list, detail.
- Runs, Providers, Settings, privacy and diagnostics live under More.
- Home is a task workbench, not a grid of feature cards.
- The execution thread is the canonical representation of assistant output, tool steps, terminal results, approvals, errors, checkpoints and evidence.

## Visual system

- Use system typography with clear title, section, body, metadata and monospaced evidence roles.
- Use the brand cyan-blue-violet only for selection, progress and the primary action.
- Reserve amber for pending decisions, red for destructive actions or failure, and green for confirmed success.
- Use Liquid Glass/material only for navigation chrome, the composer and floating actions. Reading surfaces remain opaque.
- Prefer whitespace, dividers and grouping over nested card stacks.
- Use SF Symbols in the production UI. The generated reference images are composition and atmosphere references, not pixel specifications.
- Support light/dark appearance, Dynamic Type, VoiceOver, Increased Contrast and Reduce Motion from the first implementation.

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

The iPhone reference has an exploratory tab bar. Production must use the locked five tabs above. The iPad reference is closer to the required hierarchy, but any identity/avatar or plan text shown in it is illustrative and must not be implemented.
