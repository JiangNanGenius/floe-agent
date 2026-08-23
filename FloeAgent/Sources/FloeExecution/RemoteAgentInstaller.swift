import Foundation
import Crypto
import FloeCore
import FloeTools

/// Installs or updates the same-repository Floe helper through an already
/// verified SSH host. Replacement is atomic and a failed health check restores
/// the previous working directory before returning an error.
public struct RemoteAgentInstaller: Sendable {
    public struct Result: Sendable {
        public let hostID: UUID
        public let targetKind: RemoteTargetKind
        public let version: String
        public let exitCode: Int32
        public let output: String

        public var succeeded: Bool { exitCode == 0 }
    }

    private let service: SSHCommandService

    public init(service: SSHCommandService) {
        self.service = service
    }

    public func check(
        hostID: UUID?,
        cancellation: CancellationToken? = nil
    ) async throws -> Result {
        let inspection = try await supportedInspection(hostID: hostID, cancellation: cancellation)
        let command = Self.healthCommand(expectedVersion: nil)
        let result = try await service.run(
            command: command,
            hostID: inspection.hostID,
            timeout: 15,
            maxOutputBytes: 16 * 1024,
            cancellation: cancellation
        )
        return Result(
            hostID: inspection.hostID,
            targetKind: inspection.kind,
            version: Self.version(in: result.stdout) ?? "not-installed",
            exitCode: result.exitCode,
            output: [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    public func installOrUpdate(
        hostID: UUID?,
        cancellation: CancellationToken? = nil
    ) async throws -> Result {
        let inspection = try await supportedInspection(hostID: hostID, cancellation: cancellation)
        let agent = try RemoteAgentPayload.agentSource()
        let updater = try RemoteAgentPayload.updaterSource()
        let manifest = """
        {"agent_version":"\(RemoteAgentPayload.version)","repository":"JiangNanGenius/floe-agent","bind":"127.0.0.1","port":\(RemoteAgentPayload.defaultPort)}
        """
        let command = Self.installCommand(agent: agent, updater: updater, manifest: manifest)
        let result = try await service.run(
            command: command,
            hostID: inspection.hostID,
            timeout: 90,
            maxOutputBytes: 32 * 1024,
            cancellation: cancellation
        )
        return Result(
            hostID: inspection.hostID,
            targetKind: inspection.kind,
            version: Self.version(in: result.stdout) ?? RemoteAgentPayload.version,
            exitCode: result.exitCode,
            output: [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        )
    }

    /// Creates one independent client identity for the current Apple device.
    /// The PKCS#12 password and bytes travel only inside the already verified
    /// SSH session and are deleted from the host immediately after export.
    public func enrollDevice(
        hostID: UUID,
        endpoint: String,
        deviceName: String
    ) async throws -> AdvancedRemoteEnrollment {
        _ = try await supportedInspection(hostID: hostID, cancellation: nil)
        let deviceID = UUID()
        let safeName = Data(deviceName.prefix(80).utf8).base64EncodedString()
        let command = Self.enrollmentCommand(deviceID: deviceID, deviceName64: safeName)
        let result = try await service.run(command: command, hostID: hostID, timeout: 90, maxOutputBytes: 128 * 1024)
        guard result.exitCode == 0,
              let line = result.stdout.split(separator: "\n").last,
              let data = String(line).data(using: .utf8),
              let response = try? JSONDecoder().decode(EnrollmentResponse.self, from: data),
              let pkcs12 = Data(base64Encoded: response.pkcs12),
              let serverCA = Data(base64Encoded: response.serverCA)
        else { throw FloeError.validationFailed("Advanced-link enrollment failed: \(result.stderr.prefix(512))") }
        let fingerprint = SHA256.hash(data: serverCA).map { String(format: "%02x", $0) }.joined()
        return AdvancedRemoteEnrollment(
            link: AdvancedRemoteLink(id: UUID(), hostID: hostID, deviceID: deviceID, endpoint: endpoint, port: RemoteAgentPayload.mutualTLSPort, serverCAFingerprint: fingerprint, createdAt: Date()),
            pkcs12: pkcs12, password: response.password, serverCA: serverCA
        )
    }

    private func supportedInspection(
        hostID: UUID?,
        cancellation: CancellationToken?
    ) async throws -> RemoteTargetInspection {
        let inspection = try await service.inspectTarget(hostID: hostID, cancellation: cancellation)
        guard inspection.kind == .linux || inspection.kind == .nas else {
            throw FloeError.validationFailed(
                "Floe remote agent supports paired Linux and NAS hosts only (detected \(inspection.kind.rawValue))."
            )
        }
        return inspection
    }

    private static func installCommand(agent: String, updater: String, manifest: String) -> String {
        let agent64 = Data(agent.utf8).base64EncodedString()
        let updater64 = Data(updater.utf8).base64EncodedString()
        let manifest64 = Data(manifest.utf8).base64EncodedString()
        return """
        set -eu; \
        command -v python3 >/dev/null; \
        base="$HOME/.local/lib"; current="$base/floe-agent"; next="$base/floe-agent.next"; previous="$base/floe-agent.previous"; \
        mkdir -p "$base" "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.floe/cloud-workspaces"; \
        python3 -c 'import pathlib,shutil; p=pathlib.Path.home()/".local/lib/floe-agent.next"; shutil.rmtree(p,ignore_errors=True); p.mkdir(parents=True)' ; \
        printf '%s' '\(agent64)' | python3 -c 'import base64,pathlib,sys; pathlib.Path.home().joinpath(".local/lib/floe-agent.next/floe_remote_agent.py").write_bytes(base64.b64decode(sys.stdin.buffer.read()))'; \
        printf '%s' '\(updater64)' | python3 -c 'import base64,pathlib,sys; pathlib.Path.home().joinpath(".local/lib/floe-agent.next/floe_agent_update.py").write_bytes(base64.b64decode(sys.stdin.buffer.read()))'; \
        printf '%s' '\(manifest64)' | python3 -c 'import base64,pathlib,sys; pathlib.Path.home().joinpath(".local/lib/floe-agent.next/REMOTE-AGENT-MANIFEST.json").write_bytes(base64.b64decode(sys.stdin.buffer.read()))'; \
        chmod 700 "$next/floe_remote_agent.py" "$next/floe_agent_update.py"; \
        printf '%s\n' '#!/bin/sh' 'exec python3 "$HOME/.local/lib/floe-agent/floe_remote_agent.py"' > "$HOME/.local/bin/floe-agent"; \
        printf '%s\n' '#!/bin/sh' 'exec python3 "$HOME/.local/lib/floe-agent/floe_agent_update.py" "$@"' > "$HOME/.local/bin/floe-agent-update"; \
        chmod 700 "$HOME/.local/bin/floe-agent" "$HOME/.local/bin/floe-agent-update"; \
        printf '%s\n' '[Unit]' 'Description=Floe loopback remote workspace agent' 'After=network.target' '' '[Service]' 'ExecStart=%h/.local/bin/floe-agent' 'Restart=on-failure' 'NoNewPrivileges=true' 'PrivateTmp=true' '' '[Install]' 'WantedBy=default.target' > "$HOME/.config/systemd/user/floe-agent.service"; \
        if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user stop floe-agent.service 2>/dev/null || true; else pkill -f '/.local/lib/floe-agent/floe_remote_agent.py' 2>/dev/null || true; fi; \
        python3 -c 'import os,pathlib,shutil; h=pathlib.Path.home(); c=h/".local/lib/floe-agent"; n=h/".local/lib/floe-agent.next"; p=h/".local/lib/floe-agent.previous"; shutil.rmtree(p,ignore_errors=True); c.exists() and os.replace(c,p); os.replace(n,c)'; \
        if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user daemon-reload; systemctl --user enable --now floe-agent.service; else nohup "$HOME/.local/bin/floe-agent" >"$HOME/.floe/floe-agent.log" 2>&1 & fi; \
        sleep 1; \
        if \(healthCommand(expectedVersion: RemoteAgentPayload.version)); then python3 -c 'import pathlib,shutil; shutil.rmtree(pathlib.Path.home()/".local/lib/floe-agent.previous",ignore_errors=True)'; else \
          if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user stop floe-agent.service 2>/dev/null || true; else pkill -f '/.local/lib/floe-agent/floe_remote_agent.py' 2>/dev/null || true; fi; \
          python3 -c 'import os,pathlib,shutil; h=pathlib.Path.home(); c=h/".local/lib/floe-agent"; p=h/".local/lib/floe-agent.previous"; shutil.rmtree(c,ignore_errors=True); p.exists() and os.replace(p,c)'; \
          if test -d "$current"; then if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user start floe-agent.service; else nohup "$HOME/.local/bin/floe-agent" >"$HOME/.floe/floe-agent.log" 2>&1 & fi; fi; \
          echo 'status=healthCheckFailed rollback=attempted' >&2; exit 70; \
        fi
        """
    }

    private static func enrollmentCommand(deviceID: UUID, deviceName64: String) -> String {
        """
        set -eu; command -v openssl >/dev/null; \
        pki="$HOME/.config/floe-agent/pki"; mkdir -p "$pki"; chmod 700 "$pki"; \
        if test ! -s "$pki/ca.key"; then openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$pki/ca.key" >/dev/null 2>&1; openssl req -x509 -new -sha256 -days 3650 -key "$pki/ca.key" -subj '/CN=Floe Remote CA' -out "$pki/ca.crt"; fi; \
        if test ! -s "$pki/server.key"; then printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' > "$pki/server.ext"; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$pki/server.key" >/dev/null 2>&1; openssl req -new -key "$pki/server.key" -subj '/CN=floe-agent' -out "$pki/server.csr"; openssl x509 -req -sha256 -days 825 -in "$pki/server.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" -CAcreateserial -extfile "$pki/server.ext" -out "$pki/server.crt"; fi; \
        device='\(deviceID.uuidString.lowercased())'; temporary="$pki/device-$device"; password="$(openssl rand -hex 24)"; \
        printf '%s\n' 'basicConstraints=CA:FALSE' 'keyUsage=digitalSignature' 'extendedKeyUsage=clientAuth' > "$temporary.ext"; \
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$temporary.key" >/dev/null 2>&1; \
        openssl req -new -key "$temporary.key" -subj "/CN=floe-device-$device" -out "$temporary.csr"; \
        openssl x509 -req -sha256 -days 825 -in "$temporary.csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" -CAcreateserial -extfile "$temporary.ext" -out "$temporary.crt"; \
        openssl pkcs12 -export -inkey "$temporary.key" -in "$temporary.crt" -certfile "$pki/ca.crt" -name "$device" -passout "pass:$password" -out "$temporary.p12"; \
        if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then systemctl --user restart floe-agent.service; else pkill -f '/.local/lib/floe-agent/floe_remote_agent.py' 2>/dev/null || true; nohup "$HOME/.local/bin/floe-agent" >"$HOME/.floe/floe-agent.log" 2>&1 & fi; \
        if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then (ufw allow \(RemoteAgentPayload.mutualTLSPort)/tcp comment 'Floe advanced link' >/dev/null 2>&1 || sudo -n ufw allow \(RemoteAgentPayload.mutualTLSPort)/tcp comment 'Floe advanced link' >/dev/null 2>&1 || true); fi; \
        DEVICE_NAME64='\(deviceName64)' DEVICE_ID="$device" DEVICE_PASSWORD="$password" DEVICE_P12="$temporary.p12" DEVICE_CA="$pki/ca.crt" python3 -c 'import base64,json,os,subprocess; ca=subprocess.check_output(["openssl","x509","-in",os.environ["DEVICE_CA"],"-outform","DER"]); print(json.dumps({"device_id":os.environ["DEVICE_ID"],"device_name":base64.b64decode(os.environ["DEVICE_NAME64"]).decode(),"password":os.environ["DEVICE_PASSWORD"],"pkcs12":base64.b64encode(open(os.environ["DEVICE_P12"],"rb").read()).decode(),"server_ca":base64.b64encode(ca).decode()},separators=(",",":")))'; \
        rm -f "$temporary.key" "$temporary.csr" "$temporary.crt" "$temporary.ext" "$temporary.p12"
        """
    }

    private struct EnrollmentResponse: Decodable {
        let password: String
        let pkcs12: String
        let serverCA: String
        enum CodingKeys: String, CodingKey { case password, pkcs12; case serverCA = "server_ca" }
    }

    private static func healthCommand(expectedVersion: String?) -> String {
        let versionCheck = expectedVersion.map { " and body.get(\"version\")==\"\($0)\"" } ?? ""
        return "python3 -c 'import json,pathlib,urllib.request; token=pathlib.Path.home().joinpath(\".config/floe-agent/token\").read_text().strip(); request=urllib.request.Request(\"http://127.0.0.1:\(RemoteAgentPayload.defaultPort)/v1/health\",headers={\"Authorization\":\"Bearer \"+token}); body=json.loads(urllib.request.urlopen(request,timeout=5).read()); assert body.get(\"ok\")\(versionCheck); print(json.dumps(body,separators=(\",\",\":\")))'"
    }

    private static func version(in output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["version"] as? String
    }
}
