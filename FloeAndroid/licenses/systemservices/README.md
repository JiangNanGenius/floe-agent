# C06 system services — third-party provenance

The system-services module adds exactly one pinned SDK: the stable AndroidX
Health Connect client. Location, contacts and NFC use only Android platform
APIs and add no third-party dependency.

| Coordinate | Version | License | Why |
| --- | --- | --- | --- |
| `androidx.health.connect:connect-client` | `1.1.0` (stable) | Apache-2.0 | Public Health Connect read API; `getSdkStatus` distinguishes absent/update-required providers on API 28-37 |
| `androidx.health.connect:connect-client-proto` | `1.1.0` | Apache-2.0 | Transitive wire records from the same release |
| `androidx.health.connect:connect-client-external-protobuf` | `1.1.0` | Apache-2.0 | Transitive wire protobuf from the same release |

No preview, alpha, dynamic version, GMS-only shortcut or local health database
is used. The AAR's own Apache-2.0 text is retained as `LICENSE.txt`; exact
artifact hashes and retrieval dates are in `PROVENANCE.json`.

Main must add the new coordinates to `gradle/verification-metadata.xml` (or
regenerate it with `--write-verification-metadata sha256`) and regenerate the
module/App lockfiles during the serialized qualification stage. This lane did
not run Gradle and did not modify central locks.
