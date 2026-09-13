# Build 156 distribution recovery

The source remains immutable tag `v1.7.0-beta.13`, commit `65969b8f04e67269a92b899a55620ff469d96322`. Release run 34752884723 passed SDK 27 qualification (1,244 Swift executions and 135 App regressions) and the Xcode 26.6 device build plus 135 App regressions. Apple validation then rejected desktop pnpm Mach-O resources, libssh2's literal MinimumOSVersion, and its old-SDK arm64e slice. The upload command was never reached; ASC showed build 156 only as AWAITING_UPLOAD, with no uploaded build.

The recovery policy removes six hash-reviewed non-iOS pnpm resources from the staged application, preserves libssh2's exact generic arm64 slice, and derives MinimumOSVersion 14.0 from its load commands. SDK 16.2 metadata remains truthful. Original pinned supplier archives and application source do not change. Apple signing follows normalization.

Local evidence: 14 policy/provenance tests passed; all 148 bundle executable locations were checked in the actual unsigned application; normalization passed twice with unchanged arm64 SHA-256; the normalized pnpm 9.15.9 installed and loaded an offline pure-JavaScript fixture with automatic import fallback. This macOS fixture does not replace iOS runtime or physical-device acceptance.

The recovery workflow binds the original successful job evidence, exact application source, and separate fixed distribution-policy commit. It rebuilds the same source with Xcode 26.6 and explicitly reuses the original 135 successful accepted-SDK regressions. Packaging, signing and Apple acceptance are rechecked. No TestFlight availability is claimed until VALID and IN_BETA_TESTING are verified.
