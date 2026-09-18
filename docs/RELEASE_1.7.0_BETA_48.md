# Floe1.7.0 build191 — candidate beta48

This candidate retains the Notes and runtime implementation of build190 and
isolates the mandatory network deadline regression suite from unrelated
concurrent Swift tests. Concurrency, assertions and timing requirements remain
unchanged; all three normal release gates remain required.

[Qualification and limits](qualification/build191-release/README.md).
Build190's failed SDK27 gate is preserved, alongside its passing accepted-SDK
App and Notes UI evidence. This candidate is not yet uploaded or installable.
Internal TestFlight, GitHub prerelease and Feather will be verified separately.
Public Beta submission and production publication are not part of this run.
