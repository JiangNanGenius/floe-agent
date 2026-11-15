# Prepared love.js 11.4.1 — Floe distribution profile

- npm tarball: `love.js@11.4.1`, SHA-256
  `9eb2db1f789254faed8e5cf7eeeded46a7e56ecbc931c88be809526c448d25fb`.
- Source commit (npm registry gitHead): `8f9a7b85da9149b6d4d0af46442ead1e71f76477`.
  The shipped WASM files are byte-identical to that public commit; text files
  are the same bytes after CRLF→LF normalization. The later `c4f04e18...`
  commit is LÖVE 11.5 work and is not this runtime.
- Engine: LÖVE 11.4 (zlib), compatibility runtime reports LÖVE 11.4.0.
- Build: love.js `build_lovejs.sh`, emsdk 2.0.0, `-DLOVE_JIT=0`,
  `-DCMAKE_BUILD_TYPE=Release`, `-DLOVEJS_COMPAT=1` (compat) plus the
  upstream release variant.
- LÖVE fork source pin (publish-time branch head):
  `a79ab87d82f1105e8badd39ff22cfad02882ddc1`; megasource pin
  `b1faef45bd5ec10b9b5a78ffea57401188790283`.
- `cli/` is the upstream build tool with pinned production dependencies; it is
  not a game runtime.
- LGPL component: **mpg123 1.25.6**, statically linked in the WASM. Complete
  corresponding source, delta and relink instructions are in
  `licenses/MPG123-1.25.6-COPYING.txt`,
  `licenses/LOVE-11.4-COMPONENT-ADDENDUM.md` and the distribution source
  package. OpenAL Soft and LuaJIT are named by LÖVE but are not linked in this
  build; see the addendum.
- Persistence: IDBFS is mounted at `/home/web_user/love`; it is populated at
  start and flushed only on `beforeunload` in this unmodified runtime. A new
  player does not see an unflushed save. Host persistence plus the source patch
  in `Scripts/Distribution/patches/love/` are required; this package does not
  claim durable saves for the unpatched artifact.
- No RTP, proprietary asset or native executable is included.
