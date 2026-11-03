# Remote page and reference-client tests

Run everything from the repository root:

```bash
bash FloeIOSBridge/Tests/RemoteClient/run_tests.sh
```

The suite writes its full log and browser evidence under
`Local/Private/ios-bridge-1.0-20261101/remote/evidence/`. It checks:

1. `REMOTE.html` is current relative to `remote_page.src.html` and its CSP
   hashes match the actual inline style/scripts.
2. The shipped core's SHA-256/HMAC/X25519/envelope vectors, geometry and fMP4
   parsing in both WebCrypto and pure-JS fallback VM contexts.
3. The reference client against `mock_bridge.py`: X25519 and legacy loopback
   pairing, known wire vectors, auth/engine/method/queue errors, unknown
   outcomes, no automatic retry, 0600 files, IPv6 loopback, text/journal
   hygiene, and read-only status/reconcile.
4. A real headless Edge run at a secure loopback origin and at a plain-HTTP
   LAN-shaped origin (`floe.test` mapped to loopback) with real pointer/text
   input, CSP failure detection, ticket renewal/cleanup, OCR text safety and
   responsive layouts.
5. The host resource adapter with a real `.bundle` folder reference and a
   missing-resource case.
6. Swift 6 object compilation for `arm64-apple-ios26.0` from a stable source
   snapshot, with `BridgeCore` as a separately imported module.

`browser_check.mjs` can be run alone against a running mock and Edge DevTools
port; see its usage line. `mock_bridge.py` is test-only and never touches a real
device or persisted credential.
