# floe-lua 5.4.8 provenance

Immutable WASI command artifact for the signed capability catalog entry
`floe/lua` (shell command `floe-lua`, bare-shell alias `lua`).

- Artifact: `lua.wasm`, 671143 bytes
- SHA-256: `81ad32f4eca06d232598ad7bf6f4f92bab4864a5b5d0f4da036e159b2efdf049`
- Upstream: Lua 5.4.8, `https://www.lua.org/ftp/lua-5.4.8.tar.gz`
  (sha256 recorded in `runtime.lock.json`), MIT license (`Lua-LICENSE.html`)
- Toolchain: wasi-sdk 34.0 (clang 23.1.0-wasi), wasm32-wasip1, `try_table`
  exception handling via `-fwasm-exceptions -mllvm -wasm-enable-sjlj
  -mllvm -wasm-use-legacy-eh=false` (`toolchain.txt`)
- Built by the pinned cloud job `FloeAgent/ThirdParty/LuaWASI/build_wasi.sh`
  (GitHub Actions run `35033351611`), retained locally at
  `Local/Artifacts/LuaWASI/run-35033351611/floe-lua/`.

`capability-hub/build.py` pins the size and SHA-256 above and never builds or
downloads this module; a mismatch, a missing file, or an attempt to replace it
with different bytes fails the build instead of publishing a new artifact.
