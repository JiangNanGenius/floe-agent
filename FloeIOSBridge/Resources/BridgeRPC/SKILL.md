---
name: floe-ios-bridge
description: Operate an iPhone or iPad through Floe iOS Bridge — JSON-RPC 2.0 over localhost-first HTTP, paired with owner approval and encrypted per request. Use when the user asks to inspect or operate a phone, automate an iOS app, or check why Bridge cannot reach the device.
skill_version: "1.0.0"
---

# Floe iOS Bridge 1.0

Floe iOS Bridge is a local service on the iOS/iPadOS device. It speaks **JSON-RPC 2.0**
over HTTP and is reachable by default only on the device itself:

- `http://127.0.0.1:8200/`
- `http://[::1]:8200/`

An optional normal-LAN listener can be enabled by the device owner. It is off by
default; when on, the same port is used on normal Wi-Fi/Ethernet interfaces and
the owner can separately enable `_floe-ios-bridge._tcp.` Bonjour discovery. There is no AWDL,
peer-to-peer, cellular or VPN listener. Do not assume a LAN endpoint exists until
the owner has enabled it and discovery finds it.

The automation engine is separate from setup. `/`, `/schema`, `/skill` and
`/pair` work without it. Engine methods return `engine_not_ready` until the
engine registers, and `method_not_available` until that method is implemented.
The service advertises only methods it can actually run.

## Set up once

1. Fetch `GET /schema` and `GET /skill` (this document) without pairing. They
   contain no device state or secrets.
2. Pair:
   - Loopback only: `POST /pair {"client_name":"…","plain":true}`.
   - Any connection, including LAN: `POST /pair {"client_name":"…","pub":"<raw 32-byte X25519 public key, base64>"}`.
   Every fresh pairing blocks on a device-owner approval prompt. There is no
   auto-approval and no retry shortcut; use a client timeout of at least 60 s.
   `403 pair_denied` means the owner declined or did not answer.
3. The response contains `tok` (a non-secret lookup id) and either `token`
   (32-byte key K as 64 lowercase hex) or the X25519-wrapped `pub` + `token_ct`.
   For the wrapped mode:
   ```
   shared   = X25519(client_private, response.pub)
   kWrap    = HMAC-SHA256(shared, "ictrl-pair" || client_pub || device_pub)
   pad      = HMAC-SHA256(kWrap, "ictrl-wrap")
   K        = token_ct XOR pad
   ```
4. Store K per device. A key expires only after 30 days without a successful
   call. Re-pair only on a real `401 auth_failed`.

## Encrypt every RPC

Each `POST /rpc` body is one v1 envelope. There is no plaintext or Bearer path.

```
tok       = first 4 bytes of SHA-256(K), 8 lowercase hex (lookup id, not a secret)
nonce     = 16 random bytes, never reused
ts        = unix seconds; server accepts |ts - now| <= 120
K_enc_req = HMAC-SHA256(K, "ictrl-v1|enc-req"  || nonce)
K_enc_resp= HMAC-SHA256(K, "ictrl-v1|enc-resp" || nonce)
K_mac     = HMAC-SHA256(K, "ictrl-v1|mac"      || nonce)
keystream(Kx) = HMAC-SHA256(Kx, nonce || be32(0)) || ... truncated
ct        = JSON-RPC body XOR keystream(K_enc_req)
tag       = HMAC-SHA256(K_mac, "v1" || tok_4B || be64(ts) || nonce || ct)
```

POST `{"v":1,"tok":…,"ts":…,"nonce":<32 hex>,"ct":<base64>,"tag":<64 hex>}`.
Open the response under the same nonce:
`tag == HMAC(K_mac,"resp"||nonce||ct)`, then XOR with `K_enc_resp`.
A replayed nonce is refused; a bad key/expired key returns one indistinguishable
`auth_failed`; a valid MAC with a skewed clock returns `ts_skew`.

## Endpoints

| Endpoint | Purpose |
|---|---|
| `GET /` | Product/version/capability info; no secrets |
| `GET /schema` | Method definitions and current capabilities |
| `GET /skill`, `GET /skill.md` | This manual |
| `POST /pair` | Owner-approved pairing; plain only over true loopback |
| `POST /rpc` | Encrypted JSON-RPC 2.0 |
| `GET /stream[.ts]?ticket=…` | Optional media stream; 503 when no source |
| `GET /logs?ticket=…` | Recent redacted log lines |
| `GET /logs/files?ticket=…` | Persisted log file listing |
| `GET /logs/history?date=YYYY-MM-DD&ticket=…` | Redacted history |
| `GET /remote` | Self-contained browser remote page using the same pairing and capabilities |

`stream_ticket` is an authenticated RPC that mints a single-use, ~60 s ticket for
`/stream` and `/logs*`. Those byte channels cannot carry a per-request envelope.
A ticket is consumed on first use and is revoked with its client.

Diagnostics expose bounded structured status events, including real lifecycle,
listener and DDI provenance changes. They do not expose raw host/engine logs,
input text, client identities or arbitrary files. History is available only
for retained dates. An absent event cannot prove that an interrupted action
did not happen; never replay a mutation merely because a log search is empty.

## RPC methods

The schema contains the 33 pinned method names. `available` and the
`capability_tags` array are authoritative for the connected build; never assume
a method exists just because it is documented.

Read: `device_info`, `page_source`, `screen_text`, `logs`, `screenshot`,
`find_element`, `scroll_to_element`, `collect`, `list_apps`, `resolve_app`,
`is_locked`.
Control: `config`, `tap`, `double_tap`, `long_press`, `swipe`, `page`, `scroll`,
`home`, `lock`, `unlock`, `open_url`, `launch_app`, `activate_app`,
`terminate_app`, `tap_element`, `find_and_tap`, `drag`, `wait`, `reset`.
Input: `type`, `clear_text` (ordinary input), `stream_ticket` (credential).
`screenshot` results may approach the 16 MiB encrypted-JSON cap; media belongs
on `/stream`, not inside JSON.

Ordinary `type`/`clear_text` do **not** require an extra permission. The engine
checks `invocation.sensitiveInputGranted` only when it resolves the target to a
third-party secure field. A client can never grant itself this permission by
sending a parameter; only the device owner UI can.

## Error distinctions

- Transport: malformed HTTP/oversize body, closed socket, 404/405.
- Auth: 401 `auth_required`, `auth_failed`, `ts_skew`, `nonce_replayed`,
  `nonce_flood`, `auth_unavailable`; `400 bad_envelope` for a malformed envelope.
- Request: JSON-RPC `-32600` invalid request, `-32601` method not found,
  `-32602` invalid params.
- Engine: `-32010 engine_not_ready`, `-32011 method_not_available`,
  `-32012 permission_denied`.
- Execution: `-32013 operation_outcome_unknown`, `-32016 queue_full`,
  `-32017 execution_timed_out` (not dispatched), `-32018 response_too_large`.
  A timed-out or interrupted call is never replayed automatically. If an
  `operation_id` is reused, the result is the same or an explicit unknown
  outcome — never a second SDK action.

## Operational notes

- The engine serializes SDK work: at most one real call at a time, with a
  bounded waiting queue. Do not resend a call just because a client timed out.
- Pair every fresh client with owner approval. Revocation closes that client's
  tickets, streams and in-flight HTTP connections.
- Use points for gestures and screenshots only after reading `scale` from the
  actual screenshot/device response.
- Do not retry a refused secure-field input; ask the device owner to grant it.
- `GET /schema` being reachable proves the listener is up, not that the
  automation engine is ready.
