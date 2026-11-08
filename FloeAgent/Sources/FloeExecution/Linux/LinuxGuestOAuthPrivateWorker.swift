import Foundation
import FloeCore
import FloeTools

/// Native-only errors contain no guest stdout/stderr, request, URL or token.
public enum LinuxGuestOAuthPrivateError: Error, Sendable, LocalizedError, CustomDebugStringConvertible {
    case unavailable, cancelled, protocolViolation, staleRuntime, busy, stopUnconfirmed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The private connection worker is unavailable."
        case .cancelled: "The connection was cancelled."
        case .protocolViolation: "The connection worker returned an invalid response."
        case .staleRuntime: "The selected environment has changed."
        case .busy: "This connection is already in use."
        case .stopUnconfirmed: "The previous connection worker is still stopping."
        }
    }
    public var debugDescription: String { errorDescription! }
}

public struct LinuxGuestOAuthPrivateWorkerConfiguration: Sendable {
    public let environmentID: String
    public let ownershipKey: String
    public let executablePath: String
    public let executableSHA256: String
    public let account: String
    public let configurationTOML: String
    public let useClientSecret: Bool
    public let readToken: @Sendable () async throws -> Data?
    public let writeToken: @Sendable (Data) async throws -> Void
    public let readClientSecret: @Sendable () async throws -> Data?
    public let invalidateAndJoin: @Sendable () async -> Void

    public init(environmentID: String, ownershipKey: String, executablePath: String, executableSHA256: String, account: String,
                configurationTOML: String, useClientSecret: Bool = false,
                readToken: @escaping @Sendable () async throws -> Data?,
                writeToken: @escaping @Sendable (Data) async throws -> Void,
                readClientSecret: @escaping @Sendable () async throws -> Data? = { nil },
                invalidateAndJoin: @escaping @Sendable () async -> Void) {
        self.environmentID=environmentID;self.ownershipKey=ownershipKey;self.executablePath=executablePath
        self.executableSHA256=executableSHA256
        self.account=account;self.configurationTOML=configurationTOML;self.useClientSecret=useClientSecret
        self.readToken=readToken;self.writeToken=writeToken;self.readClientSecret=readClientSecret
        self.invalidateAndJoin=invalidateAndJoin
    }
}

public protocol LinuxGuestOAuthPrivateWorker: Sendable {
    func exchange(_ request: Data) async throws -> Data
    /// False retains supervisor ownership and blocks the same connection.
    func stop() async -> Bool
}

public protocol LinuxGuestOAuthPrivateWorkerOpening: Sendable {
    func openOAuthPrivateWorker(configuration: LinuxGuestOAuthPrivateWorkerConfiguration) async throws -> any LinuxGuestOAuthPrivateWorker
}

/// Native lifecycle recovery for a start cancelled before its handle was
/// returned. This addresses only the exact connection owner, never another
/// environment's services or a guessed PID.
public protocol LinuxGuestOAuthPrivateWorkerManaging: LinuxGuestOAuthPrivateWorkerOpening {
    func stopOAuthPrivateWorkers(environmentID: String, ownershipKey: String) async -> Bool
}

public struct LinuxGuestOAuthPrivateCommandResult: Sendable, CustomDebugStringConvertible {
    public let stdout: Data
    public let exitCode: Int32
    public init(stdout: Data, exitCode: Int32) { self.stdout=stdout;self.exitCode=exitCode }
    public var debugDescription: String { "LinuxGuestOAuthPrivateCommandResult(<private>)" }
}

/// The registry pins the receipt to the ORIGINAL channel and VM handle. A
/// quarantined or replacement generation must never cause a kill of a PID
/// belonging to another VM which happened to reuse its numerical value.
public struct LinuxGuestOAuthProcessReceipt: Sendable, Equatable {
    public let reference: UUID
    public let environmentID: String
    public let generation: UInt64
    public let pid: Int32
    public init(reference: UUID, environmentID: String, generation: UInt64, pid: Int32) {
        self.reference=reference;self.environmentID=environmentID;self.generation=generation;self.pid=pid
    }
}

public struct LinuxGuestOAuthPrivateWorkerHandle: Sendable, Equatable {
    public let id: UUID
    public let ownershipKey: String
    public let process: LinuxGuestOAuthProcessReceipt
    public var environmentID: String { process.environmentID }
}

public protocol LinuxGuestOAuthPrivateHosting: LinuxGuestLocalServiceHosting {
    func oauthPrivateGeneration(environmentID: String) async throws -> UInt64
    func spawnOAuthPrivateWorker(environmentID: String, generation: UInt64,
        argv: [String], cancellation: CancellationToken?) async throws -> LinuxGuestOAuthProcessReceipt
    func stopOAuthPrivateWorker(_ receipt: LinuxGuestOAuthProcessReceipt) async -> Bool
    func runOAuthPrivate(environmentID: String, generation: UInt64, argv: [String], standardInput: Data?,
        deadline: ShellExecutionDeadline, maxOutputBytes: Int,
        cancellation: CancellationToken?) async throws -> LinuxGuestOAuthPrivateCommandResult
}

/// One service-owned pipe worker. The FIFOs are RAM endpoints; they are not
/// persistent token files. No PTY, ordinary job output, model tool, environment
/// export, or host interpreter participates in this channel.
public actor LinuxGuestOAuthPipeWorker: LinuxGuestOAuthPrivateWorker {
    private let host: any LinuxGuestOAuthPrivateHosting
    private let supervisor: LinuxGuestLocalServiceSupervisor
    private let configuration: LinuxGuestOAuthPrivateWorkerConfiguration
    private let generation: UInt64
    private let directory: String
    private var handle: LinuxGuestOAuthPrivateWorkerHandle?
    private var broker: Task<Void, Never>?
    private var tokens: [UUID: CancellationToken] = [:]
    private var joins: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var requestActive = false
    private var brokerFailed = false
    private let startCancellation = CancellationToken()
    public static let maximumFrameBytes = 65_536

    private init(host: any LinuxGuestOAuthPrivateHosting, supervisor: LinuxGuestLocalServiceSupervisor,
                 configuration: LinuxGuestOAuthPrivateWorkerConfiguration, generation: UInt64) {
        self.host=host;self.supervisor=supervisor;self.configuration=configuration;self.generation=generation
        directory="/run/floe-oauth-"+UUID().uuidString.lowercased()
    }

    public static func open(host: any LinuxGuestOAuthPrivateHosting,
                            supervisor: LinuxGuestLocalServiceSupervisor,
                            configuration: LinuxGuestOAuthPrivateWorkerConfiguration) async throws -> any LinuxGuestOAuthPrivateWorker {
        let c=configuration
        guard !c.environmentID.isEmpty, c.ownershipKey.count==64,
              c.ownershipKey.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
              c.account=="floe", c.executablePath.hasPrefix("/floe/env/"),
              c.executableSHA256.utf8.count==64,
              c.executableSHA256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
              !c.executablePath.contains(".."),
              c.executablePath.allSatisfy({$0.isLetter || $0.isNumber || "/._-".contains($0)}),
              c.configurationTOML.utf8.count<=32_768,
              !c.configurationTOML.lowercased().contains("storage."),
              !c.configurationTOML.lowercased().contains("client-secret"),
              !c.configurationTOML.lowercased().contains("hook") else { throw LinuxGuestOAuthPrivateError.protocolViolation }
        let generation=try await host.oauthPrivateGeneration(environmentID:c.environmentID)
        let worker=LinuxGuestOAuthPipeWorker(host:host,supervisor:supervisor,configuration:c,generation:generation)
        do { try await worker.start(); return worker }
        catch {
            _=await worker.stop()
            throw error is CancellationError ? LinuxGuestOAuthPrivateError.cancelled : .unavailable
        }
    }

    private func start() async throws {
        let result=try await command(Self.bootstrap, arguments:[directory,configuration.useClientSecret ? "1":"0"],
            input:Data(configuration.configurationTOML.utf8),deadline:.seconds(30))
        guard result.exitCode==0, result.stdout==Data("READY".utf8),!closed else { throw LinuxGuestOAuthPrivateError.unavailable }
        let cancellation = startCancellation
        let handle = try await withTaskCancellationHandler {
            try await supervisor.startOAuthPrivateWorker(environmentID:configuration.environmentID,
                generation:generation, ownershipKey:configuration.ownershipKey,
                argv:["/usr/bin/env","-u","BASH_ENV","-u","ENV","/bin/bash","--noprofile","--norc",
                    directory+"/worker.sh",configuration.executablePath,directory,configuration.executableSHA256],
                prepareForStop:{ [weak self] in await self?.prepareForStop() },cancellation:cancellation)
        } onCancel: { cancellation.cancel() }
        self.handle=handle
        guard !closed else { _=await supervisor.stopOAuthPrivateWorker(handle);throw LinuxGuestOAuthPrivateError.cancelled }
        broker=Task { [weak self] in await self?.brokerLoop() }
    }

    public func exchange(_ request: Data) async throws -> Data {
        guard !closed,!brokerFailed,!requestActive,!request.isEmpty,
              request.count<=Self.maximumFrameBytes,
              !request.contains(10),!request.contains(13),String(data:request,encoding:.utf8) != nil else {
            throw LinuxGuestOAuthPrivateError.protocolViolation
        }
        requestActive=true
        defer {requestActive=false}
        let result=try await command(Self.exchangeScript,arguments:[directory],input:request,deadline:.seconds(120))
        guard !closed,!brokerFailed,result.exitCode==0,!result.stdout.isEmpty,
              result.stdout.count<=Self.maximumFrameBytes else { throw LinuxGuestOAuthPrivateError.protocolViolation }
        return result.stdout
    }

    public func stop() async -> Bool {
        await prepareForStop()
        if let handle {
            guard await supervisor.stopOAuthPrivateWorker(handle) else { return false }
            self.handle=nil
        }
        await cleanup()
        return true
    }

    /// Also registered with the EXISTING supervisor. Environment stop/delete
    /// joins native credential writes and private I/O before killing the group.
    private func prepareForStop() async {
        closed=true
        startCancellation.cancel()
        await configuration.invalidateAndJoin()
        for token in tokens.values { token.cancel() }
        broker?.cancel()
        if !tokens.isEmpty { await withCheckedContinuation { joins.append($0) } }
        if let broker { await broker.value }
        self.broker=nil
    }

    private func brokerLoop() async {
        while !closed && !Task.isCancelled {
            do {
                let incoming=try await command(Self.brokerRead,arguments:[directory],input:nil,deadline:.unlimited)
                guard !closed,incoming.exitCode==0,incoming.stdout.count<=32_768,
                      let line=String(data:incoming.stdout,encoding:.utf8) else { break }
                let response:String
                do {
                    if line=="read" || line=="secret" {
                        let bytes = try await (line=="read" ? configuration.readToken() : configuration.readClientSecret())
                        if let bytes, bytes.count<=20_480 { response="OK "+bytes.base64EncodedString() }
                        else { response="MISSING" }
                    } else if line.hasPrefix("write "),
                              let bytes=Data(base64Encoded:String(line.dropFirst(6))),!bytes.isEmpty,bytes.count<=20_480 {
                        try await configuration.writeToken(bytes);response="OK"
                    } else {throw LinuxGuestOAuthPrivateError.protocolViolation}
                } catch {response="ERROR"}
                guard !closed else {break}
                let sent=try await command(Self.brokerReply,arguments:[directory],input:Data(response.utf8),deadline:.seconds(30))
                guard sent.exitCode==0 else {break}
            } catch {break}
        }
        if !closed {brokerFailed=true}
    }

    private func command(_ script:String,arguments:[String],input:Data?,deadline:ShellExecutionDeadline) async throws -> LinuxGuestOAuthPrivateCommandResult {
        guard !closed else {throw LinuxGuestOAuthPrivateError.cancelled}
        let key=UUID(),token=CancellationToken()
        tokens[key]=token
        defer {
            tokens[key]=nil
            if tokens.isEmpty {let waiting=joins;joins.removeAll();for waiter in waiting {waiter.resume()}}
        }
        return try await withTaskCancellationHandler {
            try await host.runOAuthPrivate(environmentID:configuration.environmentID,generation:generation,
                argv:["/usr/bin/env","-u","BASH_ENV","-u","ENV","/bin/bash","--noprofile","--norc","-c",script,"floe-private"]+arguments,
                standardInput:input,deadline:deadline,maxOutputBytes:Self.maximumFrameBytes,cancellation:token)
        } onCancel: {token.cancel()}
    }

    private func cleanup() async {
        let host=self.host,environmentID=configuration.environmentID,generation=self.generation,directory=self.directory
        // A new, joined task can clean its own RAM endpoints even when the
        // operation's caller is already cancelled. A stopped VM needs no cleanup.
        await Task {
            _=try? await host.runOAuthPrivate(environmentID:environmentID,generation:generation,
                argv:["/usr/bin/env","-u","BASH_ENV","-u","ENV","/bin/bash","--noprofile","--norc","-c",Self.cleanupScript,"floe-private",directory],
                standardInput:nil,deadline:.seconds(15),maxOutputBytes:128,cancellation:nil)
        }.value
    }

    private static let exchangeScript = #"""
    set -euo pipefail
    export LC_ALL=C
    d=$1
    v=$(cat)
    printf '%s\n' "$v" >"$d/mcp.in"
    IFS= read -r -n 65537 v <"$d/mcp.out"
    [ ${#v} -le 65536 ]
    printf '%s' "$v"
    """#
    private static let brokerRead = #"""
    set -euo pipefail
    export LC_ALL=C
    IFS= read -r -n 32769 v <"$1/broker.requests"
    [ ${#v} -le 32768 ]
    printf '%s' "$v"
    """#
    private static let brokerReply = #"""
    set -euo pipefail
    v=$(cat)
    printf '%s\n' "$v" >"$1/broker.responses"
    """#
    private static let cleanupScript = #"""
    set -euo pipefail
    case "$1" in /run/floe-oauth-????????-????-????-????-????????????) rm -rf -- "$1" ;; *) exit 1 ;; esac
    """#

    // Only configuration and fixed helper code are regular files. All token
    // bytes go through FIFOs. A failed probe never falls back to a host Python.
    private static let bootstrap = #"""
    set -euo pipefail
    export PATH=/usr/bin:/bin
    umask 077
    d=$1
    case "$d" in /run/floe-oauth-????????-????-????-????-????????????) ;; *) exit 1 ;; esac
    [ "$(stat -f -c %T /run)" = tmpfs ]
    for x in /bin/bash /usr/bin/base64 /usr/bin/mkfifo /usr/bin/head /usr/bin/sha256sum /usr/bin/env; do [ -x "$x" ]; done
    mkdir -m 700 -- "$d"
    cat >"$d/config.toml"
    mkfifo -m 600 "$d/mcp.in" "$d/mcp.out" "$d/broker.requests" "$d/broker.responses"
    cat >"$d/store.sh" <<'FLOE_PRIVATE_STORE'
    #!/bin/bash
    set -euo pipefail
    export PATH=/usr/bin:/bin LC_ALL=C
    d=$1
    case "$2" in
      read|secret)
        printf '%s\n' "$2" >"$d/broker.requests"
        IFS= read -r -t 30 -n 32769 v <"$d/broker.responses"
        [ ${#v} -le 32768 ]
        case "$v" in 'OK '*) printf '%s' "${v#OK }" | /usr/bin/base64 -d ;; *) exit 1 ;; esac
        ;;
      write)
        v=$(/usr/bin/head -c 20481 | /usr/bin/base64 -w 0)
        [ ${#v} -le 27308 ]
        [ "$(printf '%s' "$v" | /usr/bin/base64 -d | wc -c)" -le 20480 ]
        printf 'write %s\n' "$v" >"$d/broker.requests"
        IFS= read -r -t 30 -n 32769 v <"$d/broker.responses"
        [ ${#v} -le 32768 ]
        [ "$v" = OK ]
        ;;
      *) exit 1 ;;
    esac
    FLOE_PRIVATE_STORE
    printf '\nstorage.read.command = ["/bin/bash", "%s/store.sh", "%s", "read"]\n' "$d" "$d" >>"$d/config.toml"
    printf 'storage.write.command = ["/bin/bash", "%s/store.sh", "%s", "write"]\n' "$d" "$d" >>"$d/config.toml"
    if [ "$2" = 1 ]; then printf 'client-secret.command = ["/bin/bash", "%s/store.sh", "%s", "secret"]\n' "$d" "$d" >>"$d/config.toml"; fi
    cat >"$d/worker.sh" <<'FLOE_PRIVATE_WORKER'
    #!/bin/bash
    set -euo pipefail
    export PATH=/usr/bin:/bin RUST_LOG=off
    unset ORTIE_CONFIG BASH_ENV ENV
    d=$2
    [ "$(/usr/bin/sha256sum "$1" | cut -d ' ' -f 1)" = "$3" ]
    exec 7<>"$d/mcp.in" 8<>"$d/mcp.out" 9<>"$d/broker.requests" 10<>"$d/broker.responses"
    exec "$1" --json -c "$d/config.toml" -a floe mcp --external-loopback <&7 >&8 2>/dev/null
    FLOE_PRIVATE_WORKER
    chmod 700 "$d/store.sh" "$d/worker.sh"
    printf READY
    """#
}
