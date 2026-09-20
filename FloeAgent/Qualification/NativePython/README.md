# Retired qualification host (pre-Phase-2)

This host qualified the bundled in-process CPython runtime, which left the app
in the Phase 2 TinyEMU migration (local Python now runs inside each
environment's TinyEMU Linux guest). The project remains for recovery with its
recipes archived under `FloeAgent/ThirdParty/NativeRuntimeArchive/`; its source
references (`FloeApp/Execution/FloeCPythonBridge.m`, `Vendor/Python*`) no
longer exist at those paths, so it does not build without restoring the
archive. There is no current CI leg for it. Current guest qualification lives
in `Qualification/TinyEMULinux`.
