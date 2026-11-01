# Third-party notice — Floe Bridge browser remote

`REMOTE.html` is an independent Floe implementation. Its pairing/envelope
primitives, pairing fallback and parts of the operating-page behaviour are
adapted from **OpenMinis/iCTRL**, commit
`c1e4268859ba858d1579f7b846a56cb40641b7f6` (v1.98.16), licensed under the
Apache License, Version 2.0. The full license text is retained as
`LICENSE-iCTRL-Apache-2.0.txt` in this directory; the repository also carries
the reviewed upstream copy at `FloeIOSBridge/ThirdParty/iCTRL/LICENSE`.

Adapted: the v1 envelope direction labels and PRF-CTR construction, X25519
pairing wrap (`ictrl-pair` / `ictrl-wrap`), the pure-JS SHA-256/HMAC/X25519
fallbacks, the point-to-device coordinate approach, and the general shape of
the live-view/control page. Not imported: iCTRL's app, XCTest runner, private C
surface, `NearbyAdvertiser`/AWDL, discovery, token-file store, video encoder or
any iCTRL branding. The page is self-contained: no CDN, remote script, font,
analytics, eval, or new artwork. The icon is a mechanical 180×180 downscale of
the selected Floe Bridge app icon; see
`FloeIOSBridge/Tests/RemoteClient/fixtures/ICON_PROVENANCE.json`.

The page is a source/UI asset. It has not been accepted on a physical device or
through a full App build by this package.
