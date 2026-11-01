# Third-party notice — Floe Bridge reference client

`floe_bridge_client.py` is adapted from **OpenMinis/iCTRL**
`Scripts/ictrl_rpc.py`, commit
`c1e4268859ba858d1579f7b846a56cb40641b7f6` (v1.98.16), licensed under the
Apache License, Version 2.0. The full license text is retained as
`LICENSE-iCTRL-Apache-2.0.txt` in this directory; the repository also carries
the reviewed upstream copy at `FloeIOSBridge/ThirdParty/iCTRL/LICENSE`.

Adapted: the pure-Python RFC 7748 X25519 ladder, the HMAC-SHA256 PRF-CTR
keystream and envelope labels, and the pairing-a-phone flow. Floe changes are
substantial: localhost-first endpoints, no discovery/AWDL/`/whoami`, a 0600
per-origin client file instead of `~/.ictrl/token.json`, an append-only hashed
operation journal written before mutating POSTs, no automatic retries on
uncertain outcomes, explicit `status`/`reconcile`, and the Floe product copy.
No iCTRL account, credential or real device was used for the tests.
