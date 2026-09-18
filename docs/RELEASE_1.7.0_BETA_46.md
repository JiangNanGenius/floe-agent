# Floe1.7.0 build189 — candidate beta46

Tag `v1.7.0-beta.46` fixes source
`ba0271b247fd233ebfed9df3bd2353a9242d0cc7`.
[Cloud run35322816608](https://github.com/JiangNanGenius/floe-agent/actions/runs/35322816608)
ended with a failed SDK27 UI gate; no distribution was attempted.

This candidate repairs Notes library accessibility ownership after build188
failed the Word cover-card lookup. Embedded thumbnails no longer install a
competing element identifier; each document button publishes its actual cover
state while preserving its title and body-search excerpt. Standalone thumbnail
hosts retain their accessible representation. Generation, storage, revision
invalidation, reopen and cold-launch requirements are unchanged.

[Evidence and checks](qualification/build189-release/README.md). Local focused
checks passed; cloud UI acceptance is pending. Build188 component101/101 on
each device family and SDK27 App204/204 did not override its failed full-App
Notes UI gate. Both attempts and unique unsigned recovery artifacts are kept.
No signed IPA, TestFlight upload or installable build189 is claimed.

App-owned durable IDE CI job recovery remains included. Real-account full-App
close/reopen observation and recorded device-only Office/MLX/Pencil checks
retain their outstanding acceptance boundaries. Internal TestFlight, GitHub
prerelease and Feather will be verified separately; public Beta submission
and production release are not part of this cloud candidate dispatch.
