# C06 mail — dependency and licence record

The Android mail package adds **no new third-party Swift or Kotlin dependency**
and does not change `shared/Package.resolved`.

* Protocol, MIME, body-paging and no-replay journal behaviour is the bounded
  Android port of the fixed public Floe Agent donor at Git object
  `a59b4d4005f616c611df67fab7620e9853c525b9` (`FloeAgent/Sources/FloeExecution/
  MailAccount/MailMIME/MailBodyPaging/MailDeliveryJournal/MailMutationJournal/
  MailClient/MailWire`). The donor is part of Floe Agent and carries the
  repository's MPL-2.0 licence; no donor source is linked through a frozen
  sibling checkout.
* The real TLS transport is the Android platform's `javax.net.ssl.SSLSocket`
  (Conscrypt/default provider) with the app's existing network-security
  configuration. There is no vendored BoringSSL/MbedTLS/NIOSSL product for
  mail, no trust-all manager, no hostname-verifier override and no plaintext
  fallback. Java/Kotlin/Android platform libraries are used under their
  existing platform terms; no platform library is redistributed here.
* `MailTransportMailbox`/JNI only copies bounded ticket descriptors and
  protocol bytes. The C06 JNI translation unit is an additive member of the
  existing `floe_jni` target.
* The existing `FloeCore`/`FloePersistence`/`FloeTools`/`FloeWorkspace`
  dependencies retain their own licences; no new package pin or binary is
  introduced.

If Main later replaces the platform lane with a pinned portable TLS library,
add that library's exact revision, source and licence text here before
shipping a binary.
