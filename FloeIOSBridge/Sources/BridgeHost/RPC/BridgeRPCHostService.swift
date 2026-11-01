import Foundation

import BridgeCore

/// Bundle-backed resource provider. Expected integration:
///   Resources/BridgeRPC/SKILL.md
///   Resources/BridgeRPC/REMOTE.html   (optional; the real page arrives later)
/// The provider tries a `BridgeRPC` subdirectory and then the bundle root, so
/// either a folder reference or an expanded resource group works.
public struct BridgeRPCBundleResources: BridgeRPCResourceProvider {
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func skillMarkdown() -> String? {
        load(name: "SKILL", extension: "md")
    }

    public func remotePageHTML() -> String? {
        load(name: "REMOTE", extension: "html")
    }

    private func load(name: String, extension fileExtension: String) -> String? {
        let urls = [
            bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "BridgeRPC"),
            bundle.url(forResource: name, withExtension: fileExtension),
        ]
        for case let url? in urls {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count <= 2 * 1_024 * 1_024 else { continue }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

/// Host-facing owner API for the Bridge RPC package.
///
/// This type is the only place an app/UI should call to start listeners, open
/// LAN/Bonjour, approve pairings, grant sensitive input, or revoke clients.
/// None of those operations are reachable through a JSON-RPC payload.
public final class BridgeRPCHostService: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var requestedPort: UInt16
        public var lanEnabled: Bool
        public var bonjourEnabled: Bool
        public var limits: BridgeRPCLimits

        public init(requestedPort: UInt16 = 8200,
                    lanEnabled: Bool = false,
                    bonjourEnabled: Bool = false,
                    limits: BridgeRPCLimits = .default) {
            self.requestedPort = requestedPort
            self.lanEnabled = lanEnabled
            self.bonjourEnabled = bonjourEnabled
            self.limits = limits
        }
    }

    private let lock = BridgeRPCLock()
    private let configuration: Configuration
    private let authority: BridgeRPCAuthority
    private let registry: BridgeRPCEngineRegistry
    private let coordinator: BridgeRPCExecutionCoordinator
    private let rpcService: BridgeRPCService
    private let network: BridgeRPCNetworkServer
    private var stateHandler: (@Sendable (BridgeRPCHostSnapshot) -> Void)?
    private var ownerStopHandler: (@Sendable () -> Void)?
    private var desiredPort: UInt16
    private var desiredLAN: Bool
    private var desiredBonjour: Bool

    public init(configuration: Configuration = Configuration(),
                store: any BridgeRPCClientStore = BridgeRPCKeychainClientStore(),
                resources: any BridgeRPCResourceProvider = BridgeRPCBundleResources(),
                logs: (any BridgeRPCLogSource)? = nil,
                streamSource: (any BridgeRPCStreamSource)? = nil,
                registry: BridgeRPCEngineRegistry = BridgeRPCEngineRegistry()) {
        self.configuration = configuration
        self.registry = registry
        let authority = BridgeRPCAuthority(store: store, limits: configuration.limits)
        let coordinator = BridgeRPCExecutionCoordinator(limits: configuration.limits)
        let service = BridgeRPCService(
            configuration: BridgeRPCService.Configuration(
                requestedPort: configuration.requestedPort,
                lanEnabled: configuration.lanEnabled,
                bonjourEnabled: configuration.bonjourEnabled,
                limits: configuration.limits
            ),
            authority: authority,
            registry: registry,
            coordinator: coordinator,
            resources: resources,
            logs: logs,
            streamSource: streamSource
        )
        self.authority = authority
        self.coordinator = coordinator
        self.rpcService = service
        let network = BridgeRPCNetworkServer(service: service, limits: configuration.limits)
        self.network = network
        self.desiredPort = configuration.requestedPort
        self.desiredLAN = configuration.lanEnabled
        self.desiredBonjour = configuration.bonjourEnabled
        network.setStateHandler { [weak self] _ in
            self?.emitState()
        }
        service.setStopHandler { [weak self] in
            guard let self else { return }
            // An authenticated /rpc `config` stop is an owner-level stop: let
            // the App model fence engine work and persist the stopped intent,
            // then always close the listeners. The default close is retained
            // even when no owner handler is installed.
            self.lock.lock()
            let ownerHandler = self.ownerStopHandler
            self.lock.unlock()
            ownerHandler?()
            self.stop()
        }
        service.setClientStateHandler { [weak self] in
            self?.emitState()
        }
    }

    public var engineRegistry: BridgeRPCEngineRegistry { registry }
    public var currentService: BridgeRPCService { rpcService }

    public func setApprovalHandler(_ handler: BridgeRPCApprovalHandler?) {
        authority.setApprovalHandler(handler)
    }

    /// Installs the App-owned lifecycle hook for an authenticated RPC
    /// `config` request with `stop_server: true`. The hook is invoked from the
    /// transport's non-main callback queue; the owner must hop to the main
    /// actor. The transport still closes its listeners after the hook returns,
    /// and this API never reopens them.
    public func setStopHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        ownerStopHandler = handler
        lock.unlock()
    }

    public func setStateHandler(_ handler: (@Sendable (BridgeRPCHostSnapshot) -> Void)?) {
        lock.lock()
        stateHandler = handler
        lock.unlock()
        emitState()
    }

    /// Refreshes the observable snapshot after an engine readiness or
    /// registration change outside the network/authority callbacks.
    public func refreshState() {
        emitState()
    }

    public func start() throws {
        lock.lock()
        let port = desiredPort
        let lan = desiredLAN
        let bonjour = desiredBonjour
        lock.unlock()
        try network.start(requestedPort: port)
        if lan {
            // The loopback listeners are already live. A LAN bind failure is
            // reported to the owner and leaves localhost-first setup usable.
            try network.setLANEnabled(true, bonjour: bonjour)
        }
    }

    public func stop() {
        network.stop()
    }

    public func setLANEnabled(_ enabled: Bool) throws {
        lock.lock()
        desiredLAN = enabled
        let bonjour = desiredBonjour
        let running = snapshot().running
        lock.unlock()
        guard running else { return }
        try network.setLANEnabled(enabled, bonjour: enabled && bonjour)
    }

    public func setBonjourEnabled(_ enabled: Bool) throws {
        lock.lock()
        desiredBonjour = enabled
        let lan = snapshot().lanEnabled
        let running = snapshot().running
        lock.unlock()
        guard running, lan else { return }
        try network.setLANEnabled(true, bonjour: enabled)
    }

    @discardableResult
    public func grantSensitiveInput(clientID: String, granted: Bool) -> Bool {
        authority.setSensitiveInput(clientID: clientID, granted: granted)
    }

    @discardableResult
    public func revoke(clientID: String) -> Bool {
        authority.revoke(clientID: clientID)
    }

    /// Returns false when the durable delete failed; the in-memory client set
    /// then intentionally stays unchanged instead of claiming a revoke.
    @discardableResult
    public func revokeAll() -> Bool {
        return authority.revokeAll()
    }

    public func snapshot() -> BridgeRPCHostSnapshot {
        let networkState = network.snapshot
        let serviceSnapshot = rpcService.snapshot()
        let clients = authority.clientMetadata()
        return BridgeRPCHostSnapshot(
            running: networkState.running,
            loopbackIPv4Ready: networkState.loopbackIPv4Ready,
            loopbackIPv6Ready: networkState.loopbackIPv6Ready,
            lanIPv4Ready: networkState.lanIPv4Ready,
            lanIPv6Ready: networkState.lanIPv6Ready,
            lanEnabled: networkState.lanEnabled,
            bonjourState: networkState.bonjourState,
            port: networkState.port,
            engine: serviceSnapshot.engine,
            clients: clients,
            capabilities: serviceSnapshot.capabilities,
            storageError: authority.storeFailure,
            nonceStoreAvailable: authority.nonceStoreAvailable,
            networkError: networkState.lastError
        )
    }

    private func emitState() {
        lock.lock()
        let handler = stateHandler
        lock.unlock()
        handler?(snapshot())
    }
}
