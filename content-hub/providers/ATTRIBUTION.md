# Provider catalog attribution

`FloeAgent/FloeApp/Resources/ProviderCatalog.json` contains a baseline derived
from the public [models.dev](https://models.dev) catalog (`sst/models.dev`,
canonical repository `anomalyco/models.dev`), which is distributed under the MIT
License, plus reviewed first-party entries and fields declared in
`curated-overrides.json`.

Floe's import script (`import_models_dev.py`) copies only provider names,
curated aliases and domains, model identifiers and public documentation links.
It does not copy upstream source code, JavaScript SDK content, API keys or any
user credentials, and it does not execute upstream code. Floe curates the
provider set and maps each provider onto its own provider kinds, wire protocols
and auth styles; unsupported providers are flagged rather than dropped.
Merged upstream entries are listed per provider in `upstreamIDs`.

## First-party curated entries

`curated-overrides.json` is the single declarative source for reviewed facts
that are not models.dev data: the official Volcengine Agent Plan and Alibaba
Cloud Token Plan entries, and the Alibaba pay-as-you-go media role declarations.
The importer merges it deterministically after the pinned upstream baseline.
Those entries cite their public official documentation in the override file,
and `SOURCE.json` records the override revision, digest and the explicit
statement that they must not be attributed to models.dev. They are Floe's own
review of public provider documentation, not upstream content, and therefore
fall outside the models.dev MIT attribution below.

### Agent Plan directory refresh

The official [Ark CLI plan directory](https://github.com/volcengine/ark-cli/blob/main/skills/arkcli-plans/references/arkcli-plans-model-list.md)
provides a machine-readable source distinct from the OpenAI-compatible
`/models` endpoint:

```sh
arkcli plans model-list --plan agent-plan --mode direct
```

Use `direct_models[].model_name` as the inference model identifier. The
separate `models[]` array contains control-plane routing candidates for
`ark-code-latest`; its display names and output names are not interchangeable
with direct inference IDs. Published context, output and input-modality fields
may be absent and must not be guessed from model names. Plan-specific listing
requires Volcengine identity authentication; it is a maintainer refresh source,
not an additional login requirement or an entitlement gate in Floe.

Review the returned facts against the official plan documentation, then update
`curated-overrides.json` and regenerate through the existing importer. Keep
chat, image and independently supported audio purposes separate, preserve
manual user IDs, and do not substitute the public PAYG or Coding Plan catalog.
The bundled directory remains available offline. A model appearing in a plan
directory does not establish every account tier's entitlement, and the
developer's own subscription is not a prerequisite for users to configure it.
Keep `ark-code-latest` as a separate selectable routing entry even when the
direct-model table does not list it; do not invent a fixed context/output
limit for the selector.

As checked on 2026-11-02, current OpenCode [catalog loading](https://github.com/anomalyco/opencode/blob/dev/packages/core/src/models-dev.ts)
uses `models.opencode.ai` with a bundled snapshot and periodic refresh. Its
[public v2 directory](https://models.opencode.ai/experimental/v2.0/api.json?type=chat,decision,image)
lists Volcengine PAYG and Coding Plan, but does not contain a separate Agent
Plan provider or `ark-code-latest`. Floe therefore retains the pinned upstream
baseline and its official plan override; the Coding Plan list is not an Agent
Plan source. This is a dated directory check, not a claim that upstream will
never add the plan.

Provenance for the currently committed catalog is recorded in `SOURCE.json`.
The canonical pin is `documentSHA256`, the SHA-256 of the served
`api.json` response bytes; plain import runs and `--check` refuse to proceed
when the downloaded document no longer matches that hash, and only an explicit
`--update-source` re-pins it. models.dev serves a generated document, so the
`repositoryRevisionAtFetchTime` value is informational only and is not assumed
to be byte-identical to the served response.

## Upstream license

MIT License

Copyright (c) 2025 models.dev

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
