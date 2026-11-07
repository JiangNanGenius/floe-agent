# Third-party components

FloeFontKit's original source is MPL-2.0. This does not replace the licenses of native libraries, Web dependencies, Unicode data or the bundled WOFF2 payload.

## Native compiler

The current native producer uses `fontc 1.0.0` with default features disabled and the immutable versions/checksums in [NativeRust/Cargo.lock](NativeRust/Cargo.lock). No native library was rebuilt while collecting these notices.

- [font-native-notices.txt](../../Qualification/HeavyEditors/Notices/font/font-native-notices.txt) contains the complete original license/notice texts for 135 reachable third-party Cargo packages, including separately identified host build dependencies and proc macros.
- [source-inventory.json](../../Qualification/HeavyEditors/Notices/font/source-inventory.json) records every crate/version, archive checksum, selected license, role, platform, resolved features and original document SHA-256. Original crate archives were checked against Cargo.lock; copied cached license files were compared with those archive entries.
- The selected alternatives are Apache-2.0 for 89 packages, MIT for 29, Unicode-3.0 for 16, and Apache-2.0 **AND** Unicode-3.0 for `unicode-ident`. Extra upstream copyright/Unicode/spin and other bundled notices remain intact. The original alternative texts are retained where they carry copyright declarations; retaining them does not change the selected branch.
- The fontc workspace crates declare their own MIT/Apache terms. Their exact Cargo VCS commit is `e62f5818357f796f329f9bc1335c0e14a104ce09`; packages omitting the license file use that commit's original [workspace LICENSE](https://github.com/googlefonts/fontc/blob/e62f5818357f796f329f9bc1335c0e14a104ce09/LICENSE), selecting Apache-2.0. The historical `fontbe` repository name `googlefonts/fontmake-rs` refers to this same recorded workspace commit. This license is not applied to unrelated transitive crates.

The graph was inspected for `aarch64-apple-darwin`, `aarch64-apple-ios` and `aarch64-apple-ios-sim`. Roles describe Cargo reachability, not proof that every function survives final static linking. Dev/test/benchmark targets are excluded. In particular, the full upstream crossbeam third-party notice retains a CC-BY benchmark section without claiming that its Go benchmark is compiled into this Rust library.

## Rust toolchain and standard library

[rust-toolchain-notices.txt](../../Qualification/HeavyEditors/Notices/font/rust-toolchain-notices.txt) preserves the installed Rust 1.98.1 original MIT/Apache terms, complete standard-library `COPYRIGHT-library.html`, LLVM exception and accompanying BSD/Unicode/NCSA documents. This is separate from the 135 Cargo nodes.

The exact compiler commit is `48a229ceaefd4985c50990b14116b6d856af0985` with LLVM 22.1.8. Archive member identities match 19 installed sysroot libraries on each Apple target, including `std` and `compiler_builtins`; [rust-toolchain-source-inventory.json](../../Qualification/HeavyEditors/Notices/font/rust-toolchain-source-inventory.json) records these matches and every original document hash. Core Rust library code selects Apache-2.0 subject to the original component-specific terms. The complete upstream copyright document includes broader possible platform/build dependencies; it is not a claim that every listed component is linked, and their separate terms are not replaced with a blanket MIT declaration.

## WOFF2 payload

The bundled `woff2.wasm` is the actual `package/woff2/woff2.wasm` from `fonteditor-core 2.6.3`, verified byte for byte against the npm tarball. Its SHA-256 is `afda7e08349046612a019713c8f3baae52ee9d064c712919af020cd2634dddd6`. The archive's pinned SHA-512 npm integrity and the observed payload hashes are recorded in [woff2-source-inventory.json](../../Qualification/HeavyEditors/Notices/font/woff2-source-inventory.json).

[woff2-notices.txt](../../Qualification/HeavyEditors/Notices/font/woff2-notices.txt) preserves the original MIT copyright/permission texts for:

- [woff2-wasm](https://github.com/39ali/woff2-wasm/blob/78c679a73d6cb40056896842121297948aaec8b8/LICENSE), reference commit `78c679a73d6cb40056896842121297948aaec8b8`, Copyright (c) 2019 Ali Milhim.
- Its Google WOFF2 submodule, commit `a0d0ed7da27b708c0a4e96ad7a998bddc933c06e`, Copyright (c) 2013-2017 by the WOFF2 Authors.
- That WOFF2 source's Brotli submodule, commit `533843e3546cd24c8344eaa899c6b0b681c8d222`, Copyright (c) 2009, 2010, 2013-2016 by the Brotli Authors.

The submodule pointers and their `.gitmodules` hashes were read from those exact commits. These are license-source references. They do not assert that the npm WASM was compiled from those exact commits or reproduced locally. `fonteditor-core`'s own MIT license is retained separately by the shared npm notice collector.

The build applies a bounded CSP adaptation to the pinned Emscripten JavaScript glue. [Web/woff2-csp-patch.json](Web/woff2-csp-patch.json) records the original and patched hashes and the three replaced generators: named function wrapping, dynCall wrapping and the Embind argument/return adapter. [The build patch](../../Qualification/HeavyEditors/WebBuild/woff2-csp.mjs) verifies the complete original glue hash before replacing those bodies with ordinary closures, preserving argument count, receiver/type conversion, destructor order and return behavior. It does not modify the npm cache, install an eval/Function substitute, change the WASM or broaden CSP. The original MIT text remains intact. A VM with string code generation disabled verifies the actual data-URL WASM initialization and real TTF→WOFF2→TTF conversion, including unchanged GSUB/GPOS tables.

## Web bundle

[Web/bundle-inputs.json](Web/bundle-inputs.json) identifies the actual bundled npm inputs. The shared collector retains the complete corresponding npm license texts and combines them with the supplemental notice files above. It owns the final packaged notice aggregation; this document does not substitute a top-level license for transitive dependencies.
