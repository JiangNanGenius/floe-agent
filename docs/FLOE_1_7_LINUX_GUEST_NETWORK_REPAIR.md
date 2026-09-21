# Floe Linux guest network repair — component boot with a real device and DNS

Status: **source slice committed to a `codex/` branch; no release, tag, upload
or TestFlight change.** The repair is verified locally (pure checks, host
protocol suite, and a real TinyEMU guest boot on macOS). The final evidence
that the updated Debian component reports `net=up` is one read-only-ish cloud
workflow dispatch the coordinator owns; the job creates at most a **draft**
component release and never publishes it.

## 1. The failure (run 35645930554)

[Run 35645930554](https://github.com/JiangNanGenius/floe-agent/actions/runs/35645930554)
cross-built the static runner, replaced only `/usr/local/bin/floe-exec` in the
immutable base disk, passed the host GPL gate and built `floe_vm_host`. Every
concurrency/cancel/PTY/service marker appeared in the guest transcript, but:

```text
floe-exec: net eth0: interface configuration failed: No such device
… FLOE-CAPS hello1 runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4 net=down …
```

and `guest_protocol_check.py` then rejected the whole CAPS payload with five
`MISSING` findings (`protocol-check.json`: `capsPayload` ends in `net=down`).

### Root cause 1 — the qualification boot never attached a network device

The component workflow
(`.github/workflows/linux-guest-runner-update.yml`, step "Boot the updated
image and run the focused protocol check") invoked `floe_vm_host` **without
`--net`**. The switch is the CLI form of the App's
`LinuxGuestEnvironmentDescriptor.networkEnabled` →
`FloeVMConfig.net_enable` wiring:

- `FloeAgent/ThirdParty/TinyEMU/adapter/floe_vm.c` only opens the per-VM slirp
  backend and sets `VirtMachineParams.eth_count = 1` inside
  `#ifdef CONFIG_SLIRP` when `cfg->net_enable` is set;
- `FloeAgent/ThirdParty/TinyEMU/Sources/FloeTinyEMU/engine/riscv_machine.c`
  only creates a virtio-net MMIO device (and the matching FDT
  `virtio,mmio` node) for each `p->eth_count` entry;
- without the flag, TinyEMU registers **zero** virtio-net devices, the pinned
  2018 kernel has no `eth0`, and the runner's first-boot ioctls
  (`SIOCSIFADDR` on `eth0`, `FloeAgent/LinuxGuest/runner/floe_exec.c`) fail with
  `ENODEV`, so it honestly answered `net=down`.

The App path itself was already correct (`FloeApp/Execution/LinuxGuestBackend.swift`
sets `networkEnabled: true`; the SwiftPM target builds the adapter and slirp
with `-DCONFIG_SLIRP`); only the component qualification boot was missing the
same switch. The same workflow family's full qualification
(`tinyemu-linux-qualification.yml`) always passes `--net`.

### Root cause 2 — the pipeline CAPS parser assumed exactly four fields

`FloeAgent/scripts/linux-guest-runner-update/pipeline_contract.py` anchored
`CAPS_PATTERN` at end-of-string after `maxSessions`, so the new runner's
`net=` suffix made `parse_caps` return `None`; the manifest cross-check in
`package_component.py` and the verdict's CAPS findings all failed even before
the network state was evaluated.

## 2. The repair

| Area | Change |
| --- | --- |
| Component boot | The workflow passes `--net` to `floe_vm_host` (with a comment tying it to `FloeVMConfig.net_enable`); the read-only preflight and the offline self-check fail if a boot command loses it (`pipeline_contract.workflow_enables_guest_network`). |
| Runner resolver plan | `FloeAgent/LinuxGuest/runner/floe_net.h` now leads with slirp's **engine-served** `10.0.2.3` alias, then four public resolvers. The engine rewrites a guest datagram to the alias to the host's own first resolver (`slirp/socket.c: sosendto → get_dns_addr`, reading the host `/etc/resolv.conf`; the reply is re-addressed in `sorecvfrom/udp_output`), so a network that forces its own DNS still answers and the guest inherits the iPad/CI host's resolver. Public servers remain fallbacks when the host resolver cannot be read (slirp then falls back to loopback). |
| Runner readiness probe | `guest_bring_up_network()` (`floe_exec.c`) probes the resolvers **in order**, one short UDP query each (2 s, at most four attempts); `net=up` names the resolver that answered, `net=partial` reports the bounded total wait, and `net=down` stays an interface configuration failure. The command channel still starts without a network (local shell), so the degraded state is honest, never hidden. |
| CAPS contract | `CAPS_PATTERN` accepts an optional `net=up|partial|down`; `parse_caps` returns it, `expected_caps(..., net_status=)` renders it, and `caps_net_field()` verifies the runner source actually emits the slot. `package_component.py` only packages a verdict with `net=up` and requires the source field; a missing/`partial`/`down` state or a source without the slot fails closed. `verify_base_release.py` preflights both. |
| Real-guest proof in the cloud gate | `guest_protocol_check.py` now drives two additional guest commands: a kernel-side device read (`/sys/class/net/eth0/address` must equal the adapter's per-VM MAC `02:00:00:00:00:01` → `FLOE_NET_DEVICE_OK_…`) and a userland resolution (`getent hosts deb.debian.org` → `FLOE_NET_DNS_OK`). It also requires the runner line `net eth0=10.0.2.15/24 gw=10.0.2.2 dns=… status=up` and CAPS `net=up`, and forbids `interface configuration failed`, `No such device`, `net=down`, `net=partial`, `FLOE_NET_DEVICE_MISSING` and `FLOE_NET_DNS_FAIL`. The self-check re-derives the required MAC from `adapter/floe_vm.c`. |
| App surface | No production App code change was needed for the device/backend: `TinyEMUGuestRuntime` already sets `config.net_enable`, `LinuxGuestNetworkStatus` parses the field, and the Settings view surfaces it. Two source comments were corrected to document the field and resolver order. |

Nothing in the immutable base image, the runner-only upgrade design, the exact
source/relink packaging, the bounded cancellation semantics or the
`up/partial/down` vocabulary changed. `floe_net.h` is still the same single
header already covered by the exact-source digest and LGPL relink archive.

## 3. Local verification (this Mac, arm64)

Pure/host checks:

```sh
make -C FloeAgent/LinuxGuest/runner host check-clock check-net
# clock_arg_check: 87 checks, 0 failures; net-plan-check: 45 checks passed
bash FloeAgent/LinuxGuest/tests/host_protocol_check.sh
# protocol checks 18/18; runtime lifecycle 5/5
python3 FloeAgent/scripts/linux-guest-runner-update/selfcheck.py --repo . --out <dir>   # PASSED
python3 -m unittest discover -s FloeAgent/scripts/linux-guest-runner-update -p 'test_*.py'  # 17 tests OK
```

The self-check covers the new contract directly: CAPS parsing with and
without the field; unknown value rejected; `caps_net_field` positive and
negative; the workflow `--net` guard with negatives (a comment or a prose
sentence naming the flag is rejected; a missing flag on the real workflow
fails); the required guest eth0 MAC re-derived from the six
`net->mac_addr[i] = 0x..` assignments in `adapter/floe_vm.c`; synthetic
`net=up`/`net=partial`/`net=down`/probe-failed transcripts; and packaging that
refuses `down`, `partial`, a missing field, and a source without the slot.

When this slice was finished, the focused unit suite caught three fail-open
gaps in the first cut of the guard code (all fixed before commit): the
runner-source CAPS regex matched a comment containing `net=`; the workflow
guard missed an inline `--net` on a continuation line; and it accepted the
prose "floe_vm_host --net appears nowhere as a command". The checks now pin
all three cases.

Real TinyEMU build and guest boots (adapter `Makefile`, `MACOS=1`, pinned
2019-12-21 pristine + patches; pinned 2018 demo bbl/kernel — the **same
bbl/kernel bytes as the Debian component image**):

- `lifecycle_test`: `LIFECYCLE_OK (0 failures)`; `two_vm_test`: 23/23,
  `TWO_VM_OK`; `containment_test`: 65/65, `CONTAINMENT_OK`.
- Boot **with** `--net`: `/proc/net/dev` lists `eth0`;
  `ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up` succeeds;
  `ping 10.0.2.2` answers (`FLOE_LOCAL_PING_OK`); guest TCP to the real
  internet works (busybox `wget` to a raw IPv4 Fastly address returned an HTTP
  response through slirp).
- A guest UDP round-trip through the pinned slirp to a host-side UDP listener
  worked (TFTP RRQ received on the Mac and the guest received the reply:
  `tftp: server error: (1) not served`), i.e. the host-socket UDP relay and
  reply encapsulation are functional on Darwin.
- Boot **without** `--net` reproduces run 35645930554's mechanism: no `eth0`
  and `ifconfig eth0 …` fails, which is exactly what the new forbidden-marker
  gate rejects.

The 2018 demo rootfs is a minimal buildroot whose C library does not send DNS
queries at all (`/proc/net/snmp` `Udp OutDatagrams` stays 0 for `nslookup`,
`ping <name>` and `wget <name>`), so DNS cannot be proven from that rootfs.
The engine-side DNS alias is instead proven by the earlier real-Debian
qualification run 35500083112 (2026-09-20), where the shipped Debian guest was
configured with only `nameserver 10.0.2.3` and `apt-get update`, an apt install
and an HTTPS fetch all returned success. The cloud component re-dispatch
below re-proves it with the new runner and the stricter gate.

## 4. Remote-only step (coordinator) — exact cloud path

Dispatch the read-only-preflight + draft-only update from the branch commit;
the boot must end with `FLOE-END p3done 0`, the transcript must carry the
runner `status=up` line, `FLOE_NET_DEVICE_OK_02:00:00:00:00:01`,
`FLOE_NET_DNS_OK` and CAPS `net=up`:

```sh
gh workflow run linux-guest-runner-update.yml \
  --repo JiangNanGenius/floe-agent --ref codex/tinyemu-guest-network-repair \
  -f target_commit=<40-hex SHA on the branch> \
  -f component_tag=floe-linux-guest-20260922.2 \
  -f image_id=floe-debian13-riscv64-20260922.2
gh run watch --repo JiangNanGenius/floe-agent <run-id>
# evidence: linux-guest-runner-update-evidence-<run>/protocol-evidence/protocol-check.json
```

Pass criteria: job `update` green; `protocol-check.json` has
`"netStatus": "up"`, `failures: 0`; the draft release is created only after
that. If GitHub's host network ever blocks the DNS path, the job fails openly
at the network gate (it must not be weakened): the runner then reports
`partial`/`down`, which is an honest degraded state the Settings UI already
surfaces, and the component is not packaged.

## 5. Licenses

No new source, engine patch or dependency was added for this repair; the
network backend is the existing MIT adapter plus BSD-licensed slirp compiled
with `-DCONFIG_SLIRP`. The complete corresponding-source offer for the static
runner (`floe_exec.c`, quoted headers including `floe_net.h`, `Makefile`) and
the LGPL-2.1 relink object are unchanged in shape and now cover the resolver
plan that produces the packaged `runnerCapabilities` (`… maxSessions=4
net=up`).
