# Design Direction

## Threaded Operations Desk

Floe Agent uses a **Threaded Operations Desk** model: every agent task is a durable thread, and every consequential action leaves inspectable evidence. The experience should feel calm, native, and operational rather than theatrical.

## Information architecture

- iPhone uses five primary areas: Home, Chat, Files, Hosts, and More.
- iPad uses a three-column workspace for navigation, task or session selection, and detail.
- The execution thread is the canonical view of assistant output, tool steps, terminal results, approvals, errors, checkpoints, and evidence.
- Home is a task workbench, not a grid of disconnected feature cards.

## Interaction principles

1. Every screen should make the current state, next action, required decision, and available evidence clear.
2. Approval surfaces show the exact scope, host, command or tool, risk reason, and expiry before execution.
3. Stop remains reachable during a run or remote session.
4. Disconnected, suspended, failed, and unknown states never resemble success.
5. iPad keyboard and pointer behavior is first-class; iPhone retains complete functionality.

## Visual and accessibility baseline

- Use native system typography and restrained cyan-blue-violet accents.
- Reserve amber for pending decisions, red for destructive actions or failure, and green for confirmed success.
- Prefer whitespace, dividers, and clear grouping over nested card stacks.
- Support Dynamic Type, VoiceOver, Increased Contrast, Reduce Motion, keyboard navigation, pointer input, light and dark appearance, and iPad multitasking.
- Never communicate status by color alone; interactive targets are at least 44 × 44 points.
