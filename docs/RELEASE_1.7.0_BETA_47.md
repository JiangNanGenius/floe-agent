# Floe1.7.0 build190 — candidate beta47

This candidate retains189's Notes library implementation and corrects two
cloud-validation setup paths: card lookup is confined to the Notes library,
and simulator boot is completed before starting UI tests. All product checks
and normal release gates remain required.

[Preflight and limits](qualification/build190-release/README.md).
Build189's accepted-SDK iPad and iPhone UI tests passed, but its SDK27 failures
remain failures; this candidate does not relabel them. TestFlight, GitHub
prerelease and Feather delivery will be verified separately after qualification.
Public Beta submission and production publication are not authorized here.
