// FloeAgentRuntime — child-side progressive tool discovery.
//
// A delegated child holds the parent run's ACTUAL effective tool ceiling, but
// it does NOT receive the whole catalog as frozen schemas: a full catalog
// serializes to hundreds of kilobytes and cannot ride inside the child's
// bounded 48 KiB frozen-schema allowance. Instead the child gets the same
// progressive-discovery workflow the main run already uses:
//
//   * a small stable seed (tools.list/tools.search, skills, checklists, the
//     shell entry point and the child-only sibling tools),
//   * `tools.list` / `tools.search` handled INSIDE the child, loading
//     definitions into the child's own versioned discovery state,
//   * `skill.read` results activating their declared `requiredToolNames` in
//     the CHILD (never in the parent's audit-only bookkeeping),
//   * admission/drop/eviction inside the real wire-byte schema budget.
//
// Discovery is presentation, never authority: a loaded schema does not grant
// anything and an unloaded schema does not forbid anything. Every call still
// resolves through the parent runtime's canonical dispatch path. This state
// is per child and never mutates the parent's or a sibling's discovery set.

import Foundation
import FloeCore
import FloeProviders
import FloeTools

/// Per-child progressive schema selection.
struct ChildToolDiscovery: Sendable {
    /// One admission result: what is in the child's context now, what was
    /// newly admitted, what stayed out (budget) and which individual
    /// definition is too large to ever load.
    struct LoadReceipt: Sendable {
        var admitted: [String] = []
        var alreadyLoaded: [String] = []
        var deferred: [String] = []
        var oversized: [String: Int] = [:]
        var evicted: [String] = []
        var matched: [String] = []
    }

    /// Child-only sibling collaboration tools. They exist solely for
    /// delegated children and are part of the stable seed when the parent
    /// catalog offers them.
    static let peerToolNames: Set<String> = ["delegate.peers", "delegate.message"]

    /// Runtime-virtual discovery tools. They are not in the executor catalog;
    /// the runtime handles them directly (in the child loop for a child).
    static let discoveryToolNames: Set<String> = [ToolDiscovery.name, ToolDiscovery.listName]

    /// Frozen discovery universe: every descriptor this child may discover,
    /// already filtered by the parent's effective ceiling and boundary rules.
    let offered: [ToolCatalog.Descriptor]
    private let offeredByName: [String: ToolCatalog.Descriptor]

    /// Names the child's context must always carry when they exist: the
    /// seed. Sorted for a deterministic wire order.
    let pinned: [String]

    /// Schemas currently loaded, in priority order (most recently requested
    /// first) after the pinned seed.
    private(set) var loaded: [String]
    private(set) var priority: [String]

    /// Version of this child's LOCAL discovery state. Bumped on every
    /// admission/eviction so a child can reason about its own state and tests
    /// can prove siblings/parent never share it.
    private(set) var revision: Int = 0

    /// Evictions since the last request: surfaced as an explicit system note
    /// (never silent), then drained.
    private var evictionNotices: [String] = []

    init(descriptors: [ToolCatalog.Descriptor], seedNames: Set<String>) {
        let sorted = descriptors.sorted { $0.name < $1.name }
        self.offered = sorted
        // The two runtime-virtual discovery tools are always loadable even
        // though the executor catalog does not list them (the child loop
        // handles them itself, exactly as the main run does).
        var byName = Dictionary(uniqueKeysWithValues: sorted.map { ($0.name, $0) })
        byName[ToolDiscovery.name] = ToolDiscovery.descriptor
        byName[ToolDiscovery.listName] = ToolDiscovery.listDescriptor
        self.offeredByName = byName
        let presentSeed = seedNames.intersection(Set(byName.keys))
        self.pinned = presentSeed.sorted()
        self.loaded = presentSeed.sorted()
        self.priority = presentSeed.sorted()
    }

    /// The default seed: the main run's pinned discovery base plus the
    /// child-only sibling tools. `tools.search`/`tools.list` are always
    /// present even when the executor catalog does not list them.
    static func seedNames(
        offeredNames: Set<String>,
        includeChildOnlyPeers: Bool,
        extra: Set<String> = []
    ) -> Set<String> {
        var names = ToolDiscovery.coreNames.intersection(offeredNames)
        names.formUnion(discoveryToolNames)
        if includeChildOnlyPeers {
            names.formUnion(peerToolNames.intersection(offeredNames))
        }
        names.formUnion(extra.intersection(offeredNames))
        return names
    }

    // MARK: Byte accounting

    /// Real wire ledger for one frozen definition: the same conservative
    /// JSON-escaped accounting the request composer uses.
    static func schemaWireBytes(_ descriptor: ToolCatalog.Descriptor) -> Int {
        schemaOverheadBytes + SubagentRunner.wireEscapedBytes(descriptor.name)
            + SubagentRunner.wireEscapedBytes(descriptor.toolDescription)
            + SubagentRunner.wireEscapedBytes(descriptor.parametersJSON)
    }

    static let schemaOverheadBytes = 128
    static let toolNameOverheadBytes = 16

    /// The tool-name ceiling carried alongside the frozen schemas. Names are
    /// cheap (a name mapping, never the full schema); they must cover every
    /// name the model may legitimately call — including names whose schema
    /// was evicted and any pending call — so compat-wire reverse mapping
    /// stays total.
    func ceilingNames(pendingCallNames: Set<String> = []) -> [String] {
        var names = offered.map(\.name)
        names.append(contentsOf: Self.discoveryToolNames)
        names.append(contentsOf: pendingCallNames)
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    func namesLedgerBytes(pendingCallNames: Set<String> = []) -> Int {
        ceilingNames(pendingCallNames: pendingCallNames).reduce(0) {
            $0 + Self.toolNameOverheadBytes + SubagentRunner.wireEscapedBytes($1)
        }
    }

    /// Startup guard: the stable seed plus the name ceiling must fit, or the
    /// child cannot open a valid request at all. Returns an explicit message
    /// instead of dispatching an over-budget request.
    func startupFailure(maxBytes: Int) -> String? {
        let namesBytes = namesLedgerBytes()
        let seedBytes = loaded.reduce(0) { total, name in
            guard let descriptor = offeredByName[name] else { return total }
            return total + Self.schemaWireBytes(descriptor)
        }
        guard namesBytes + seedBytes > maxBytes else { return nil }
        return "Subagent frozen tool schemas exceed the bounded schema allowance "
            + "(\(namesBytes + seedBytes) > \(maxBytes) wire bytes) before the first request"
    }

    // MARK: Selection

    /// Builds the exact frozen schemas for the next child request. Order:
    /// pinned seed first (deterministic), then most-recently loaded.
    func schemas() -> [ToolSchemaDescriptor] {
        loaded.compactMap { offeredByName[$0] }.map {
            ToolSchemaDescriptor(
                name: $0.name,
                description: $0.toolDescription,
                parametersJSON: $0.parametersJSON
            )
        }
    }

    /// Loads definitions into the child's context within the real wire-byte
    /// schema budget.
    ///
    /// Deterministic admission order, highest priority first: the pinned seed,
    /// then protected previously loaded definitions, then the current request
    /// in request order, then ordinary retained definitions by recency. A
    /// definition is admitted only when it fits the REAL
    /// remaining budget, so an older definition can never displace a newer one
    /// and nothing is admitted only to be evicted again for a later name.
    ///
    /// * pinned seed is always kept (a caller checks `startupFailure` first);
    /// * newly requested names are admitted in request order;
    /// * `protected` names are never evicted: they are retained ahead of
    ///   ordinary recency and are always kept when they fit;
    /// * a single definition larger than the entire remaining non-pinned
    ///   budget is reported as `oversized` for THIS definition only — it never
    ///   aborts the child or the catalog; any other definition that cannot fit
    ///   is `deferred`;
    /// * EVERY previously loaded definition that does not survive the pass is
    ///   reported in `evicted` (deduplicated, oldest first) and always changes
    ///   the discovery revision — a schema loss is never silent;
    /// * a newly requested definition that had to wait is `deferred`/
    ///   `oversized`, never misreported as an evicted older name.
    mutating func load(
        _ requested: [String],
        maxBytes: Int,
        protected: Set<String> = []
    ) -> LoadReceipt {
        var requestedNames: [String] = []
        var seenRequested = Set<String>()
        for name in requested where offeredByName[name] != nil && !pinned.contains(name) {
            guard seenRequested.insert(name).inserted else { continue }
            requestedNames.append(name)
        }
        let pinnedSet = Set(pinned)
        let requestedSet = Set(requestedNames)
        let previous = Set(loaded)

        // Recency order of the currently loaded definitions, most recently
        // requested first: `priority` carries the retained order and the wire
        // order covers anything without an entry. The retained pass follows
        // this order, so newer definitions keep their schemas before older
        // ones are considered.
        var retainedOrder: [String] = []
        var seenRetained = Set<String>()
        for name in priority + loaded where previous.contains(name) {
            guard seenRetained.insert(name).inserted else { continue }
            retainedOrder.append(name)
        }
        // Reserve protected schemas before admitting new requests: merely
        // processing them before ordinary retention would still let a new
        // request consume their entire budget. They are a subset of the
        // previously fitting working set under this unchanged byte ceiling.
        let protectedRetained = retainedOrder.filter { protected.contains($0) }
        let retainedPass = retainedOrder.filter { !protected.contains($0) }

        let schemaBudget = maxBytes - namesLedgerBytes()
        var used = 0
        var kept: [String] = []
        var receipt = LoadReceipt()
        receipt.matched = Array(Set(requested).filter { offeredByName[$0] != nil }).sorted()

        func size(_ name: String) -> Int {
            offeredByName[name].map(Self.schemaWireBytes) ?? 0
        }
        let pinnedBytes = pinned.reduce(0) { $0 + size($1) }

        // Admission is monotone: a definition is kept only when it fits the
        // REAL remaining budget, and nothing admitted earlier is later evicted
        // for a name that comes after it in the priority order.
        func admit(_ name: String) -> Bool {
            let bytes = size(name)
            guard used + bytes <= schemaBudget else { return false }
            kept.append(name)
            used += bytes
            return true
        }

        // 1) Pinned seed: always part of the child context.
        for name in pinned {
            _ = admit(name)
        }
        // Hard retention precedes new requests. A request that would displace
        // one of these schemas is deferred instead.
        for name in protectedRetained where !kept.contains(name) {
            _ = admit(name)
        }
        // 2) Current requests in request order — the highest priority after
        //    pinned and protected schemas. A request that cannot fit is reported for
        //    itself; it never evicts a retained definition and is never
        //    counted as an evicted older name.
        for name in requestedNames {
            guard !kept.contains(name) else { continue }
            if admit(name) { continue }
            let bytes = size(name)
            if bytes > schemaBudget - pinnedBytes {
                receipt.oversized[name] = bytes
            } else {
                receipt.deferred.append(name)
            }
        }
        // 3) Previously loaded definitions. They keep whatever budget the
        //    current requests left; an older definition that no longer fits is
        //    dropped and surfaced below as an explicit eviction.
        for name in retainedPass where !kept.contains(name) {
            _ = admit(name)
        }

        let keptSet = Set(kept)
        receipt.admitted = kept.filter { !previous.contains($0) }
        receipt.alreadyLoaded = kept.filter { previous.contains($0) && requestedSet.contains($0) }
        self.loaded = kept
        // Priority: newest request first, then everything retained in the
        // relative order it already had.
        var newPriority: [String] = []
        var seenPriority = Set<String>()
        for name in requestedNames + priority + kept where keptSet.contains(name) {
            guard seenPriority.insert(name).inserted else { continue }
            newPriority.append(name)
        }
        self.priority = newPriority
        // EVERY previously loaded definition that disappeared is an eviction:
        // deduplicated, oldest first, surfaced as an explicit notice, and
        // paired with a real revision change so a silent schema loss can
        // never occur again. The pinned seed is excluded: it is never evicted,
        // and `startupFailure` refuses to open a request without it.
        receipt.evicted = retainedOrder.reversed().filter {
            previous.contains($0) && !pinnedSet.contains($0) && !keptSet.contains($0)
        }
        if !receipt.admitted.isEmpty || !receipt.evicted.isEmpty {
            revision += 1
            evictionNotices.append(contentsOf: receipt.evicted)
        }
        return receipt
    }

    /// Activates the `requiredToolNames` declared by a `skill.read` result.
    /// This runs in the CHILD: skill metadata is never permission, so names
    /// outside the child's offered ceiling are ignored and every loaded
    /// schema still needs the canonical dispatch approval to execute.
    mutating func activateSkillDependencies(
        _ names: [String],
        maxBytes: Int,
        protected: Set<String> = []
    ) -> LoadReceipt {
        load(names, maxBytes: maxBytes, protected: protected)
    }

    /// Drains the pending eviction notices (surfaced as an explicit note in
    /// the next child request, never silently lost).
    mutating func takeEvictionNotices() -> [String] {
        defer { evictionNotices = [] }
        return evictionNotices
    }

    /// Rebuilds the exact wire ledger for a schema set this discovery state
    /// produced, so request composition can double-check its own bound.
    static func schemaLedgerBytes(
        _ schemas: [ToolSchemaDescriptor],
        allToolNames: [String]
    ) -> Int {
        let schemaBytes = schemas.reduce(0) { partial, schema in
            partial + schemaOverheadBytes
                + SubagentRunner.wireEscapedBytes(schema.name)
                + SubagentRunner.wireEscapedBytes(schema.description)
                + SubagentRunner.wireEscapedBytes(schema.parametersJSON)
        }
        return schemaBytes + allToolNames.reduce(0) {
            $0 + toolNameOverheadBytes + SubagentRunner.wireEscapedBytes($1)
        }
    }

    // MARK: Display / search

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        offeredByName[name] ?? Self.virtualDescriptor(named: name)
    }

    /// The virtual discovery descriptors are injected by the runtime; the
    /// child's tools.list must be able to describe them even though the
    /// executor catalog does not contain them.
    static func virtualDescriptor(named name: String) -> ToolCatalog.Descriptor? {
        switch name {
        case ToolDiscovery.name: return ToolDiscovery.descriptor
        case ToolDiscovery.listName: return ToolDiscovery.listDescriptor
        default: return nil
        }
    }

    /// Descriptors shown to `tools.list`: the discovery universe plus the two
    /// virtual discovery tools.
    var listableDescriptors: [ToolCatalog.Descriptor] {
        offered + [ToolDiscovery.descriptor, ToolDiscovery.listDescriptor]
    }
}
