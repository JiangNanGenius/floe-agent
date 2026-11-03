# Floe Bridge reference client

A deliberately small, dependency-free Python client for the pinned Floe Bridge
v1 wire contract. It is for pairing, inspection and transparent JSON-RPC calls;
it is not a replacement for the Floe app UI and has not been qualified against
a real phone by this package.

## 要求 / Requirements

- Python 3.9+ (the system `python3` is enough; no third-party packages).
- A reachable Floe Bridge service, by default `http://127.0.0.1:8200`; IPv6
  loopback is `http://[::1]:8200`.
- The device owner must approve the one-time pairing prompt in Floe Bridge.
- No account, Apple ID, developer certificate or downloaded helper is needed.

The client only uses `http://` because Bridge is a local same-origin service.
It never discovers devices, scans the LAN, opens ports, or retries a mutating
action without an explicit user decision.

## 快速开始 / Quick start

From this directory (or use an absolute path):

```bash
# 1. Pair. The owner sees the request; compare the printed key fingerprint.
python3 floe_bridge_client.py pair --name "My Mac"

# 2. Read-only status. No mutation is performed.
python3 floe_bridge_client.py status

# 3. Inspect the device.
python3 floe_bridge_client.py call device_info
python3 floe_bridge_client.py call screen_text '{"scale":0.3}'

# 4. A control action. Coordinates are in device points.
python3 floe_bridge_client.py call tap '{"x":100,"y":200}'

# 5. UTF-8 text is read from stdin, not argv.
printf 'Hello 世界' | python3 floe_bridge_client.py type --submit

# 6. Save an image. The base64 response is decoded locally; nothing is printed.
python3 floe_bridge_client.py shot ./floe-shot.jpg --scale 1

# 7. Save one bounded /stream response. It mints one single-use ticket.
python3 floe_bridge_client.py stream ./live.bin --seconds 5
```

Pair with X25519 by default. `--plain` is a legacy loopback-only grant and is
discouraged even on loopback. A plaintext grant cannot be used over the LAN.

## 文件与秘密 / Files and secrets

- The default client file is
  `~/.floe/bridge/client-<origin-hash>.json`, directory `0700`, file `0600`.
  Use `--client-file PATH` to choose an explicit path; it is still forced to
  `0600`. Group/world-readable files are refused, not silently accepted.
- `pair --force` replaces an existing local client file. `forget` removes the
  local key and journal. **Neither revokes access on the device.** To end
  access, open Floe Bridge → Clients on the device and revoke the client there.
- The pairing key is never printed, put in a URL, or written to the journal.
  The journal stores only the method, endpoint, token id, operation id and
  the outcome. It stores neither parameters nor their hashes, and no typed
  text, screenshots, ticket values or key material.
- `--json` is available for machine-readable status/call output. Generic call
  output redacts `ticket`, `token`, `key`, `key_hex` and `token_ct` fields.

## 未确认结果 / Unknown outcomes and retries

`tap`, `type`, `drag`, `home`, `launch_app` and the other mutating methods are
recorded as `dispatched` **before** the POST. If the connection drops, a reply
is unverified, or the device returns `-32013`/`-32017`, the client exits `4`,
marks the operation `unknown`, and **never retries automatically**. Check the
device, then run:

```bash
python3 floe_bridge_client.py reconcile
```

`reconcile` is read-only: it prints unconfirmed journal entries and, when
available, the device's redacted log lines. A JSON-RPC `id` is only a
correlation id; it is not an idempotency key. For one actual single intent you
may pass a stable `--operation-id` to `call`; the same id means the same intent,
not a new action. The client generates one for mutating calls by default.

Exit codes: `0` success, `2` usage, `3` pairing/auth, `4` unknown outcome,
`5` transport/protocol/server error.

## 常用命令 / Useful commands

```bash
python3 floe_bridge_client.py --host '[::1]:8200' status
python3 floe_bridge_client.py --host 192.0.2.10:8200 status   # only if LAN enabled
python3 floe_bridge_client.py schema
python3 floe_bridge_client.py call page ''                    # empty params
python3 floe_bridge_client.py call drag '{"from_x":100,"from_y":400,"to_x":100,"to_y":120}'
python3 floe_bridge_client.py call page_source '{"visible_only":true}'
```

Methods are exactly the pinned upstream names; the device's `/schema` is
authoritative for availability. The client does not invent a method or treat
`device_info` as proof that the automation engine is ready; an
`engine_not_ready` error is distinct from `auth_failed`.

## 已知限制 / Known limitations

- No discovery, AWDL, peer-to-peer, cellular or VPN transport.
- HTTP only. TLS termination, if any, belongs to a fronting proxy and is not
  part of this package.
- The pure-Python X25519 ladder is used so pairing works with the system
  interpreter; use the shipped client, not a hand-written fragment.
- The reference client does not decode video. `stream` saves the exact bytes it
  receives; the browser remote is the viewer.
- This package is source/test evidence only. Native device acceptance,
  TestFlight/App Store publication and the full App build remain with the main
  release owner.

The adapted upstream notice and Apache-2.0 text are in `NOTICE.md` and
`LICENSE-iCTRL-Apache-2.0.txt`.
