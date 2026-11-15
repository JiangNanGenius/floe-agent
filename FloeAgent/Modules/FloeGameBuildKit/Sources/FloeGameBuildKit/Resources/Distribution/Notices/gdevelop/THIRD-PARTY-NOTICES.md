# Third-party notices

## GDevelop (Core, GDJS, newIDE, official extensions)

This package uses the official GDevelop 5.6.287 SDK/release for export and
includes the official GDJS runtime output in its test fixture. GDevelop is
published under the MIT license. The GDevelop name and logo are trademarks of
their owner and are not licensed by the MIT grant.

Source: https://github.com/4ian/GDevelop/tree/v5.6.287
Pinned commit: `cfaccd2c20bba2b43fea529523042249c90b9a41`

Folder license references:

- `Core/LICENSE.md` — MIT, Copyright (c) 2008-2016 Florian Rival
- `GDJS/LICENSE.md` — MIT, Copyright (c) 2008-2017 Florian Rival
- `newIDE/LICENSE.md` — MIT, Copyright (c) 2017 Florian Rival

MIT License text (as used by the GDevelop folders):

```text
The MIT License (MIT)

Copyright (c) 2008-2017 Florian Rival

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
```

The official exported bundle contains `LICENSE.GDevelop.txt`; the export
verifier requires that file to be present and the test fixture retains it.

The Root-reviewed export recipe additionally retains the full notices for
PIXI 7.4.2 (MIT), howler 2.2.3 (MIT), Font Face Observer 2.0.13 (verbatim
upstream BSD notice), rbush 2.0.1 (MIT), and its quickselect dependency (ISC).
Texts are in `LicenseTexts` and in the bundled
`gdevelop-third-party-notices.txt`; every newly produced export receives them
under `licenses/GDevelop-runtime-third-party.txt`, included in its sealed
file manifest. Runtime bytes and their original headers remain unchanged.
Private retrieval receipts bind the exact text/source hashes. The historical
quickselect 1.0.0 archive declares ISC but omits a license file; the full
upstream ISC notice from 1.1.0 is retained. The vendored body omits three
default-parameter assignments; the rbush browser bundle otherwise matches
2.0.1 after one comment spelling correction and trailing whitespace.

This notice set does not assert that arbitrary imported extensions, fonts,
images, audio or a future SDK export have been reviewed. They retain their own
licenses and do not inherit the GDevelop MIT label.

## Development-time schema bootstrap

The starter project JSON shape was generated once with
`gdcore-tools@2.0.0-gd-v5.6.269-autobuild` (MIT,
https://github.com/arthuro555/gdcore-tools), a wrapper around GDevelop Core.
It is not a runtime/build dependency of this package and its code/binaries are
not redistributed here. The produced project is exported by the official
5.6.287 SDK and is covered by the package tests and the real export evidence.

## Floe dependencies

- `FloeGameKit` / `FloeGameCore` — MPL-2.0 (path dependency).
- `FloeGameBuildKit` — MPL-2.0 (path dependency; provides typed host command
  and execution port only).
- `ZIPFoundation` is a transitive dependency of `FloeGameBuildKit`, MIT,
  Copyright 2017-2025 Thomas Zoechling. No ZIPFoundation source is copied into
  this package.

## Qualification tooling (not shipped)

Playwright/Chromium was used only as a private headless qualification browser
in the host's private qualification workspace; it is not a package dependency, is not bundled and is
not an App runtime/executor. The real engine check is evidence, not product
code.
