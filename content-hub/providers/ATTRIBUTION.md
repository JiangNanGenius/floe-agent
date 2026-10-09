# Provider catalog attribution

`FloeAgent/FloeApp/Resources/ProviderCatalog.json` is derived from the public
[models.dev](https://models.dev) catalog (`sst/models.dev`, canonical repository
`anomalyco/models.dev`), which is distributed under the MIT License.

Floe's import script (`import_models_dev.py`) copies only provider names,
curated aliases and domains, model identifiers and public documentation links.
It does not copy upstream source code, JavaScript SDK content, API keys or any
user credentials, and it does not execute upstream code. Floe curates the
provider set and maps each provider onto its own provider kinds, wire protocols
and auth styles; unsupported providers are flagged rather than dropped.
Merged upstream entries are listed per provider in `upstreamIDs`.

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
