# Install and use Floe iOS Bridge

> This guide covers the standalone app. Check the [release centre](https://www.floe-agent.com/releases?platform=ios-bridge) for available packages and each version's qualification scope.

Floe iOS Bridge is a standalone, self-signed app for iPhone and iPad running iOS/iPadOS 26 or later. This release does not integrate with the main Floe app. One IPA contains the host, local development tunnel and automation engine; no separate VPN or debugging helper app is required at runtime.

## First setup: use a computer once

Prepare development signing with the Network Extension capability, a development certificate, and matching host and Packet Tunnel provisioning profiles. The first release does not guarantee free Apple ID or arbitrary re-signing tool compatibility. It does not sign in to Apple ID or issue certificates inside the app.

1. Obtain the unsigned IPA and its `.sha256` from the official release, then verify SHA-256. The public package contains no developer provisioning profiles, device identifiers or pairing records.
2. Use the source from the same release tag, then re-sign with your own material using its [signing script](scripts/sign_bridge_ipa.sh). Run its `--help` for arguments. It checks permissions and signs nested frameworks, the VPN extension, test bundle and host in order. Signing only the outer app is insufficient.
3. Use a host Bundle ID registered by your developer team, with `.tunnel` appended for the extension. Using the default ID requires matching profiles. Do not patch identifier strings inside executables.
4. Connect and unlock the device, enable Developer Mode, and install the signed app. Complete any system trust confirmation on the device.
5. Generate this device's **RemotePairing development record** on the computer and import it through Bridge setup. It is different from a Lockdown record and from a client control key. Do not share or publish it. See the steps below.
6. Install Bridge's built-in local VPN configuration. Enter any required device passcode only on the device.
7. End computer developer-tool connections, open Bridge on the device, download or import its runtime image, and start the service.

The DDI is downloaded or imported on demand and is never bundled in the IPA. Initial setup may require internet access; later starts can reuse validated local assets. The tunnel serves only the local development address `10.7.0.1/32`, without an internet default route or DNS replacement.

### Create the development pairing record

Use the official [idevice_pair tool](https://github.com/jkcoxson/idevice_pair#usage) on the computer, preferably over USB for this one-time setup:

1. Connect and unlock the device, complete any system Trust prompt and keep it on the Home Screen.
2. Select the device, choose **Remote pairing**, use **Load / Create**, then save the record to a file. Use **Validate** when available.
3. Keep the file in a protected local location, transfer it to the device and import it in Bridge setup. Do not choose **Lockdown**: a regular `idevicepair pair` or SideStore record cannot open this development tunnel.

The tool also offers Wi-Fi onboarding, which its guide describes as in-memory state. That alone does not establish reboot durability; the Bridge version's recovery result remains the authority. Client pairing inside Bridge is a separate authorization and does not replace this step.

Use Wi-Fi and internet access for the first mount. Apple may need to issue a device personalization ticket; cached image files do not guarantee that every later mount can run offline.

## Everyday use: on the device

Open Bridge, check the home status and select Start Service. A usable address appears only after actual readiness. After reboot, unlock the device and open Bridge; it attempts recovery when the service was previously intended to run. An explicit Stop remains stopped. Automatic execution at device boot is not promised.

The system may request UI automation confirmation or the device passcode again. Complete these on the device. Bridge does not bypass the lock screen or system authentication.

Primary addresses are `http://127.0.0.1:8200` and `http://[::1]:8200` on the same device. Every new client, including a local client, requests pairing and requires confirmation in Bridge. Revoke clients from the client page or stop the service at any time.

For same-device Safari remote control, request pairing, switch to Bridge to approve, then return to Safari. A request received in the background waits for this confirmation or expires; it is never approved automatically.

Third-party app password input requires a separate sensitive-input grant for that client, disabled by default. This grant never permits device passcode entry or system authentication input.

Bridge's own controls require direct interaction on the device. Paired automation cannot tap or type into Bridge to approve clients or change permissions.

## Optional local network access

LAN access and same-network discovery are off by default. Enable them in Settings only when another device needs to connect. Discovery uses the same LAN and does not provide direct peer-to-peer nearby connections. New LAN clients also need approval on the device.

Turning LAN access off preserves local access. Stopping closes service entrances; revocation ends a client's subsequent access and streaming connections. Browser remote control shares the same authentication and service state as other clients.

## Recovery with minimal intervention

| Condition | Action |
| --- | --- |
| Expired signature or provisioning profile | Re-sign and install with valid material; prefer updating the same Bundle ID in place. |
| Expired or revoked client authorization | Pair that client again and approve in Bridge; a new device development record is unnecessary. |
| Invalid device development pairing | Regenerate and import the RemotePairing record through first setup; a computer may be required. |
| Missing runtime image | Download or import it inside Bridge and inspect the actual recovery result. |
| Unknown installation outcome | Preserve the state and check actual mount status as directed before attempting another installation. |
| Engine initialization failure | Fully close and reopen Bridge; do not initialize XCTest twice in one process. |
| Rejected VPN permission or an existing VPN conflict | Check system authorization and conflicts; Bridge does not delete other VPN configurations. |

Changing the Bundle ID or signing team can create a separate app, Keychain and VPN configuration. Do not assume automatic data migration. Consult actual runtime results and release notes after system updates.

Pairing records, signing material and client keys are private. Use redacted diagnostics when reporting an issue; do not attach passwords, raw pairing records, provisioning profiles or unchecked recordings.

## Qualification boundaries

An owner-accepted reboot recovery assumption is recorded separately from device tests and disclosed in the corresponding release notes.

Compilation, signing and installation, device behavior, and public downloads are separate evidence. By project-owner direction, iPad compatibility is assumed rather than physically qualified. The release notes identify the actual iPhone checks for each version.
