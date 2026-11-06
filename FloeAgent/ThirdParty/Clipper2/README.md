# Clipper2

Source-only packaging of [PolyClipping/Clipper2](https://github.com/PolyClipping/Clipper2)
at commit `b496b454df168a2280354857c1cd90bd6fa7b4dd` for the Floe media
qualification adapter.

- `Sources/Clipper2Cpp` — untouched upstream headers and the two translation
  units required for boolean and offset operations.
- `Sources/Clipper2C` — a thin, project-authored C ABI (`clipper2_c.h`) over
  `Clipper64` and `ClipperOffset`.
- `PIN.txt` — exact source hashes, license, and the exact copy list.
- `LICENSE` — Boost Software License 1.0.

The package is intentionally not added to `FloeAgent/Package.swift`. It is
consumed only by `FloeAgent/Qualification/MediaExchange` so the main App build
does not acquire a C++ dependency. Geometry callers must supply explicit
quantization and tessellation tolerances; the C ABI owns no document, model or
UI state.
