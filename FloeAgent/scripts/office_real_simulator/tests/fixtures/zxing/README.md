# Pinned ZXing recipe fixtures

These MPL-2.0 source files are copied unchanged from Collabora's engine pin
`27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc`, under `engine/external/zxing/`.
They retain the upstream license notices.

- `UnpackedTarball_zxing.mk`: SHA256 `cff0aa5e8c97c88145fd69a1545b5df2b49e1ad2474a7a785b1ee19d9e041893`
- `StaticLibrary_zxing.mk`: SHA256 `94b6fc709b4fee331846f4f7d12ca93dc1ab598b05e3935e53e37df278275340`

The unpack recipe documents unused dangling links to an experimental submodule.
The static-library recipe does not build libzint objects. Primary inspection of
the actual `zxing-cpp-2.3.0.tar.gz` from LibreOffice's source server verified its
SHA256 `64e4139103fdbc57752698ee15b5f0b0f7af9a0331ecbdc492047e0772c417ba`
against this pin's `engine/download.lst`, and checked all 36 header links,
including the two nested font headers. The tests require exact recipe hashes
and exact reviewed link/target mappings; changed recipes, unknown headers and
other missing headers fail. This is dependency-packaging evidence, not Office
or PPT runtime acceptance.
