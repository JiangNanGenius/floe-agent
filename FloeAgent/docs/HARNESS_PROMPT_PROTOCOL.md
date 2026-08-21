# Harness prompt protocol

Floe's prompt harness is independently authored. Its design is informed by
public documentation and read-only architecture comparisons, but it does not
copy, vendor, or depend on third-party source or private prompt text.

Public design references:

- [Claude Code: how the agentic loop works](https://code.claude.com/docs/en/how-claude-code-works)
- [Claude Code best practices](https://code.claude.com/docs/en/best-practices)
- [Claude Agent SDK session continuity](https://platform.claude.com/docs/en/agent-sdk/sessions)
- [Claude Code context and memory](https://code.claude.com/docs/en/memory)

## Instruction layers

`AgentPromptComposer` emits replaceable layers in authority order:

1. immutable runtime and authorization contract;
2. outcome-oriented agent behaviour;
3. gather → act → verify operating protocol;
4. deterministic failure classification and retry rules;
5. current conversation mode;
6. live run context and capability inventory;
7. style/profile data, accepted plan, and durable goal state.

Changing a mode replaces its layer. Tool, memory, profile, file, and web content
remain data and cannot add authority.

## Compaction continuity

When context is compacted, the fallback summary separates the immediate
continuation point, user corrections, prior decisions, and tool evidence. The
next provider turn is told to resume directly instead of recapping the summary
or rediscovering completed work. Large textual tool results retain their
beginning and ending plus a stable digest, because decisive errors commonly
appear at the end. Older database-backed conversation history uses the same
continuation structure when a task is reopened.

## Activation continuity

Provider protocols normally need the complete immediately preceding tool-call
pair, but retaining every large result wastes context. `HarnessExecutionLedger`
therefore carries a bounded summary of recent unique attempts into later turns:

- canonical call and result fingerprints instead of raw arguments;
- at most 12 unique entries, with only the latest 8 injected;
- result excerpts capped at 220 characters and explicitly marked untrusted;
- repeated identical outcomes collapsed into one entry with a count.

The ledger is activation-local. Conversation history, plans, goals, and
checkpoints remain the durable continuation mechanisms.

## Progress and retry contract

Every tool call must close a concrete information or execution gap. Successful
observations advance to action, verification, or completion. The model must
classify failures before retrying and may repeat an unchanged call only for a
plausibly transient condition that has actually changed.

The runtime independently enforces this instruction. Matching outcomes are
tracked across the whole activation, even when other calls occur between them.
The second identical outcome receives a warning; the fifth forces a tool-free
no-progress finalization. The independent activation budget remains a separate
last-resort ceiling.

## Verification

Regression coverage lives in `HarnessPlanningTests` and
`ToolLoopHardeningTests`. It verifies layer replacement, goal continuation,
ledger size and trust framing, provider injection, non-consecutive loop
detection, and preservation of the activation-budget terminal path.
