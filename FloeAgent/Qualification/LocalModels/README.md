# FloeLocalModelsQualification (Build 235)

Deterministic, weight-free contract gate for the Build 235 local-model
"fabricated provider tool name" repair.

## Device failure being pinned

A local Qwen turn for "随便搜索一下今天的新闻" first produced no valid tool call;
on retry it printed prose followed by a JSON envelope that named the **search
provider** instead of the registered tool:

```
好的，我来帮你搜索一下今天的新闻。
{"tool_call":{"name":"bochaWeb","arguments":{"query":"今天新闻"}}}
```

`bochaWeb` is a `WebSearchProviderKind` backend enum (see
`FloeExecution/WebRetrievalModels.swift`), never a registered tool. The
canonical capability is `web.search` (`FloeExecution/Tools/WebSearchTool.swift`).
The envelope parsed to zero calls, was not executed, yet its raw JSON was shown
as the answer and the model claimed to be searching.

## What this host proves (and what it does not)

It drives the production `LocalProviderAdapter` with a scripted text engine
(no weights, no network, no real inference), the **real** `WebSearchTool`
schema, and a production-shaped synthetic `web.search` result payload.

- every `WebSearchProviderKind` enum is rejected as a tool name (never aliased
  or executed);
- the canonical `web.search` envelope parses/executes;
- prose + a rejected-name envelope (bare or ```json fenced, including
  character-fragmented streaming) is withheld from the visible answer and
  correctively repaired **once** into the admitted `web.search` schema;
- a production-shaped result embedding provider raw values and real result
  items grounds the receipt continuation (items reach the prompt, no repeat
  call, synthetic marker preserved) — the no-fabrication gate;
- an empty/count-only result never becomes a call and never forces a repeat.

This is **not** iPad or real-weight acceptance. Real model honesty is measured
separately by the MLX `Qualification/LocalInference` host; deterministic
fixtures cannot claim a prompt or parser change fixes generation behaviour.

## Run

```
swift build --package-path FloeAgent/Qualification/LocalModels \
  --scratch-path FloeAgent/.build --jobs 2
.build/debug/FloeLocalModelsQualification   # under the shared scratch Products dir
```

Set `DEVELOPER_DIR` to the installed Xcode (the Command Line Tools toolchain
cannot compile MLX's Metal sources). Exit code 0 with `"passed": true` is
success; JSON evidence is printed to stdout.
