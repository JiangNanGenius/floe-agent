import Foundation
import FloeCore
#if canImport(Darwin)
import Darwin
#endif

/// Only observation seams. Production and tests share the same no-follow file
/// reader; a test cannot replace it with a recursive/user-content reader.
struct LegacyRecoveryInventorySeams: Sendable {
    var monotonicNow: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var wallNow: @Sendable () -> Date = { Date() }
    var isCancelled: @Sendable () -> Bool = { Task.isCancelled }
    var cloneAttributes: @Sendable (Int32) -> StorageCloneAttributeResult = {
        StorageCloneAttributesReader.read(descriptor: $0)
    }
}

public enum LegacyRecoveryInventory {
    public static func scan(_ request: LegacyRecoveryInventoryRequest) -> LegacyRecoveryInventoryReport {
        scan(request, seams: LegacyRecoveryInventorySeams())
    }

    static func scan(_ request: LegacyRecoveryInventoryRequest,
                     seams: LegacyRecoveryInventorySeams) -> LegacyRecoveryInventoryReport {
        #if canImport(Darwin)
        let reader = Reader(request: request, seams: seams)
        return reader.run()
        #else
        return LegacyRecoveryInventoryReport(
            capturedAt: Date(), rootIdentity: nil, rootDiagnostic: nil, directoryEntriesVisited: 0,
            sidecarReadsAttempted: 0, sidecarBytesRead: 0, diskContentBytesRead: 0,
            stopReasons: ["unsupportedPlatform"], records: [],
            summary: LegacyRecoveryInventorySummary(isPartial: true))
        #endif
    }
}

#if canImport(Darwin)
private extension LegacyRecoveryInventory {
    struct RuntimeMetadata: Decodable {
        let version: Int
        let runtimeID: String
        let environmentID: String
        let baseImageID: String
        let bootBaseDiskDigest: String?
        let templateID: String?
        let templateVersion: Int?
        let templateDigest: String?
    }
    struct EnvironmentMetadata: Decodable {
        let version: Int
        let environmentID: String
        let baseImageID: String
        let baseRootfsSHA512: String
        let templateID: String?
        let templateVersion: Int?
        let templateDigest: String?
    }
    struct RepairMarker: Decodable {
        let version: Int
        let environmentID: String
        let runtimeID: String
        let holdID: String
        let preservedPath: String?
    }
    struct SmallRead {
        var observation: LegacyRecoverySidecarObservation
        var data: Data?
    }
    struct DiskRead {
        var state: LegacyRecoveryObservationState
        var identity: LegacyRecoveryFileIdentity?
        var attributes: StorageCloneAttributes?
        var backup: LegacyRecoveryAttributePresence = .unknown
    }

    final class Budget {
        let limits: LegacyRecoveryInventoryLimits
        let seams: LegacyRecoveryInventorySeams
        let started: TimeInterval
        var entries = 0
        var reads = 0
        var bytes = 0
        var reasons: [String] = []
        init(_ limits: LegacyRecoveryInventoryLimits, _ seams: LegacyRecoveryInventorySeams) {
            self.limits = limits; self.seams = seams; self.started = seams.monotonicNow()
        }
        var stopped: Bool { !reasons.isEmpty }
        func stop(_ reason: String) {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        func check() -> Bool {
            if seams.isCancelled() { stop("cancelled"); return false }
            if seams.monotonicNow() - started >= limits.maximumDuration {
                stop("timeBudget"); return false
            }
            return !stopped
        }
        func visitEntry() -> Bool {
            guard check() else { return false }
            guard entries < limits.maximumDirectoryEntries else { stop("entryBudget"); return false }
            entries += 1; return true
        }
        func beginRead() -> Bool {
            guard check() else { return false }
            guard reads < limits.maximumSidecarReads else { stop("sidecarReadBudget"); return false }
            reads += 1; return true
        }
        func acceptBytes(_ count: Int) -> Bool {
            guard count >= 0, count <= limits.maximumTotalSidecarBytes - bytes else {
                stop("sidecarByteBudget"); return false
            }
            // These bytes were already returned by read(2), including if the
            // deadline/cancellation arrived during that syscall.
            bytes += count; return check()
        }
    }

    final class Reader {
        let request: LegacyRecoveryInventoryRequest
        let seams: LegacyRecoveryInventorySeams
        let budget: Budget
        let capturedAt: Date
        var rootDiagnostic: LegacyRecoveryRootDiagnostic?
        init(request: LegacyRecoveryInventoryRequest, seams: LegacyRecoveryInventorySeams) {
            self.request = request; self.seams = seams
            self.budget = Budget(request.limits, seams); self.capturedAt = seams.wallNow()
        }

        func run() -> LegacyRecoveryInventoryReport {
            guard request.legacyRoot.isFileURL else {
                rootDiagnostic = .init(stage: .inputValidation, posixErrno: EINVAL, componentIndex: nil)
                budget.stop("rootUnavailable"); return finish(nil, [])
            }
            guard budget.check() else { return finish(nil, []) }
            // Only the App-authorized root may have fixed OS ancestors resolved
            // (for example /var -> /private/var). Foundation URL presentation is
            // not proof of POSIX canonicality. The existing root is realpath'd,
            // then opened component-by-component with O_NOFOLLOW. No sidecar or
            // descendant path is ever sent through realpath.
            let opened = LegacyRecoveryInventory.openCanonicalDirectory(request.legacyRoot.path)
            let rootFD = opened.descriptor
            guard rootFD >= 0 else {
                rootDiagnostic = opened.diagnostic
                budget.stop("rootUnavailable"); return finish(nil, [])
            }
            defer { close(rootFD) }
            guard let rootIdentity = LegacyRecoveryInventory.identity(rootFD) else {
                let code = errno
                rootDiagnostic = .init(stage: .rootIdentity, posixErrno: code, componentIndex: nil)
                budget.stop("rootUnavailable"); return finish(nil, [])
            }
            var records: [LegacyRecoveryInventoryRecord] = []
            for parent in [["recovery", "quarantine"], ["runtime", "vm"]] {
                guard budget.check() else { break }
                let parentFD = LegacyRecoveryInventory.openDirectory(rootFD, parent)
                if parentFD < 0 {
                    if errno != ENOENT { budget.stop("supportedParentUnavailable") }
                    continue
                }
                let duplicate = dup(parentFD)
                guard duplicate >= 0, let stream = fdopendir(duplicate) else {
                    if duplicate >= 0 { close(duplicate) }
                    close(parentFD); budget.stop("directoryReadFailed"); break
                }
                defer { closedir(stream); close(parentFD) }
                while budget.check() {
                    errno = 0
                    guard let item = readdir(stream) else {
                        if errno != 0 { budget.stop("directoryReadFailed") }
                        break
                    }
                    let name = withUnsafePointer(to: item.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self,
                            capacity: MemoryLayout.size(ofValue: item.pointee.d_name)) {
                            String(cString: $0)
                        }
                    }
                    if name == "." || name == ".." { continue }
                    guard budget.visitEntry() else { break }
                    guard let expectedRuntimeID = LegacyRecoveryInventory.supportedRuntimeID(parent: parent, name: name) else { continue }
                    guard records.count < request.limits.maximumRecords else {
                        budget.stop("recordBudget"); break
                    }
                    records.append(inspect(rootFD: rootFD, rootIdentity: rootIdentity,
                        components: parent + [name], expectedRuntimeID: expectedRuntimeID))
                }
            }
            if LegacyRecoveryInventory.identity(rootFD) != rootIdentity { budget.stop("rootChangedDuringScan") }
            return finish(rootIdentity, records)
        }

        func inspect(rootFD: Int32, rootIdentity: LegacyRecoveryFileIdentity,
                     components: [String], expectedRuntimeID: String) -> LegacyRecoveryInventoryRecord {
            let relative = components.joined(separator: "/")
            var blockers: [LegacyRecoveryPlanningBlocker] = []
            let directoryFD = LegacyRecoveryInventory.openDirectory(rootFD, components)
            let directoryIdentity = directoryFD >= 0 ? LegacyRecoveryInventory.identity(directoryFD) : nil
            if directoryFD >= 0 { close(directoryFD) }
            if directoryIdentity == nil { blockers.append(.unsupportedDirectory) }
            var disk = inspectDisk(rootFD, components + ["disk.img"])
            if disk.state == .changedDuringRead { blockers.append(.diskChanged) }
            if disk.state != .present || (disk.identity?.logicalBytes ?? 0) <= 0 {
                blockers.append(.diskUnavailable)
            }
            if let links = disk.identity?.linkCount, links != 1 { blockers.append(.linkedDisk) }

            var runtimeRead = readSmall(rootFD, components + ["runtime.json"])
            var runtime: RuntimeMetadata? = decode(RuntimeMetadata.self, read: &runtimeRead)
            if let value = runtime,
               !(1...2).contains(value.version) || !LegacyRecoveryInventory.safeID(value.runtimeID, .runtime)
                || !LegacyRecoveryInventory.safeID(value.environmentID, .environment)
                || !LegacyRecoveryInventory.safeID(value.baseImageID, .image) {
                runtime = nil; runtimeRead.observation.state = .malformed
            }
            let runtimeMatches = runtime?.runtimeID == expectedRuntimeID
            if runtime == nil { blockers.append(.runtimeMetadataUnavailable) }
            else if !runtimeMatches { blockers.append(.runtimeIdentityMismatch) }
            let environmentID = runtime?.environmentID
            var environmentRead = notRequested()
            var markerRead = notRequested()
            var generationRead = notRequested()
            var environment: EnvironmentMetadata?
            var marker: RepairMarker?
            var generation: Int64?
            if let environmentID {
                let base = ["environments", environmentID]
                environmentRead = readSmall(rootFD, base + ["metadata.json"])
                environment = decode(EnvironmentMetadata.self, read: &environmentRead)
                let generationBefore = readSmall(rootFD, base + ["repair-hold.generation"])
                markerRead = readSmall(rootFD, base + ["repair-hold.json"])
                marker = decode(RepairMarker.self, read: &markerRead)
                generationRead = readSmall(rootFD, base + ["repair-hold.generation"])
                if generationBefore.observation.state != generationRead.observation.state
                    || generationBefore.observation.identity != generationRead.observation.identity
                    || generationBefore.observation.sha256 != generationRead.observation.sha256 {
                    generationRead.observation.state = .changedDuringRead
                }
                if let data = generationRead.data {
                    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let parsed = text.flatMap(Int64.init)
                    if generationRead.observation.state == .present, let parsed, parsed >= 0 {
                        generation = parsed
                    } else if generationRead.observation.state == .present {
                        generationRead.observation.state = .malformed
                    }
                }
            }
            let environmentMatches = environment?.version == 1
                && environment?.environmentID == environmentID
            if environment == nil { blockers.append(.environmentMetadataUnavailable) }
            else if !environmentMatches { blockers.append(.environmentIdentityMismatch) }
            if generationRead.observation.state != .present && generationRead.observation.state != .missing {
                blockers.append(.generationUnmeasured)
            }
            let repairMatches = marker.map {
                $0.version == 2 && $0.environmentID == environmentID && $0.runtimeID == runtime?.runtimeID
                    && UUID(uuidString: $0.holdID) != nil
            }
            if markerRead.observation.state != .present && markerRead.observation.state != .missing {
                blockers.append(.unreadableRepairMarker)
            } else if marker != nil && repairMatches != true { blockers.append(.repairIdentityMismatch) }

            var holdPath: LegacyRecoveryHoldPathState = .noReadableMarker
            if let marker, repairMatches == true, let preserved = marker.preservedPath {
                if let parts = LegacyRecoveryInventory.supportedPreservedPath(preserved),
                   LegacyRecoveryInventory.supportedRuntimeID(parent: Array(parts.dropLast()), name: parts.last ?? "") == expectedRuntimeID {
                    if parts == components { holdPath = .exactPhysicalLocation }
                    else {
                        let alternate = inspectDisk(rootFD, parts + ["disk.img"])
                        switch alternate.state {
                        case .present: holdPath = .differentLocationHasDisk
                        case .missing: holdPath = .differentLocationMissingDisk
                        default: holdPath = .differentLocationUnmeasured
                        }
                    }
                } else { holdPath = .unsafe; blockers.append(.unsafeRepairPath) }
            } else if marker != nil && marker?.preservedPath == nil {
                blockers.append(.unreadableRepairMarker)
            }
            let baseComparison: LegacyRecoveryBaseComparison
            if let runtime, let environment, environmentMatches,
               let boot = runtime.bootBaseDiskDigest, LegacyRecoveryInventory.validSHA512(boot),
               LegacyRecoveryInventory.validSHA512(environment.baseRootfsSHA512) {
                if runtime.baseImageID != environment.baseImageID {
                    baseComparison = .differs
                } else if runtime.templateID != nil || runtime.templateVersion != nil || runtime.templateDigest != nil
                    || environment.templateID != nil || environment.templateVersion != nil || environment.templateDigest != nil {
                    // A template pin's digest identifies the template content,
                    // not necessarily its disk blob. Do not compare it as if it
                    // were the raw rootfs digest without the owner's registry.
                    baseComparison = runtime.templateID == environment.templateID
                        && runtime.templateVersion == environment.templateVersion
                        && runtime.templateDigest == environment.templateDigest ? .unknown : .differs
                } else {
                    baseComparison = boot.lowercased() == environment.baseRootfsSHA512.lowercased() ? .matches : .differs
                }
            } else { baseComparison = .unknown }
            let references = referenceState(environmentID, now: seams.wallNow())
            addReferenceBlocker(references, to: &blockers)
            if let source = disk.identity, disk.state == .present,
               !matchesPathIdentity(rootFD, components + ["disk.img"], source) {
                disk.state = .changedDuringRead; disk.attributes = nil; disk.backup = .unknown
                blockers.append(.diskChanged)
            }
            let recognized = disk.state == .present && (disk.identity?.logicalBytes ?? 0) > 0 && runtimeMatches
            return LegacyRecoveryInventoryRecord(
                relativeDirectory: relative, environmentID: environmentID, runtimeID: runtime?.runtimeID,
                recordedBaseImageID: runtime?.baseImageID,
                recordedTemplateID: (runtime?.templateID).flatMap { LegacyRecoveryInventory.safeID($0, .template) ? $0 : nil },
                recordedTemplateVersion: runtime?.templateVersion,
                recordedTemplateDigest: (runtime?.templateDigest).flatMap { LegacyRecoveryInventory.validSHA512($0) ? $0 : nil },
                recordedBootBaseDigest: (runtime?.bootBaseDiskDigest).flatMap { LegacyRecoveryInventory.validSHA512($0) ? $0 : nil },
                environmentBaseDigest: environment.map(\.baseRootfsSHA512).flatMap { LegacyRecoveryInventory.validSHA512($0) ? $0 : nil },
                baseComparison: baseComparison,
                diskState: disk.state, privateBytes: disk.attributes?.privateBytes,
                cloneID: disk.attributes?.cloneID, cloneReferenceCount: disk.attributes?.cloneRefCount,
                cloneExtendedFlags: disk.attributes?.extendedFlags, backupExcludeAttribute: disk.backup,
                runtimeIdentityMatchesDirectory: runtimeMatches, environmentIdentityMatches: environmentMatches,
                repairIdentityMatches: repairMatches,
                recordedPreservedDirectory: (marker?.preservedPath).flatMap {
                    LegacyRecoveryInventory.supportedPreservedPath($0)?.joined(separator: "/")
                }, holdPathState: holdPath,
                hasRecognizedPhysicalEvidence: recognized,
                mustPreserveRepairEvidence: true,
                repairAcknowledgementsInspected: false, currentReferenceState: references,
                planningBlockers: Array(Set(blockers)).sorted { $0.rawValue < $1.rawValue },
                reviewSnapshot: LegacyRecoveryReviewSnapshot(
                    rootIdentity: rootIdentity, directoryIdentity: directoryIdentity, diskIdentity: disk.identity,
                    runtimeMetadata: runtimeRead.observation, environmentMetadata: environmentRead.observation,
                    repairMarker: markerRead.observation, repairGeneration: generationRead.observation,
                    observedRepairGeneration: generation,
                    observedHoldID: (marker?.holdID).flatMap { UUID(uuidString: $0) == nil ? nil : $0 },
                    capturedAt: seams.wallNow(), referenceCapturedAt: request.currentReferences?.capturedAt))
        }

        func finish(_ rootIdentity: LegacyRecoveryFileIdentity?,
                    _ input: [LegacyRecoveryInventoryRecord]) -> LegacyRecoveryInventoryReport {
            _ = budget.check()
            var records = input
            for index in records.indices {
                let reference = referenceState(records[index].environmentID, now: seams.wallNow())
                records[index].currentReferenceState = reference
                addReferenceBlocker(reference, to: &records[index].planningBlockers)
                if budget.stopped && !records[index].planningBlockers.contains(.inventoryIncomplete) {
                    records[index].planningBlockers.append(.inventoryIncomplete)
                }
            }
            var summary = LegacyRecoveryInventorySummary()
            summary.isPartial = budget.stopped; summary.recordCount = records.count
            var arithmeticOverflow = false
            func add(_ value: Int64, to total: inout Int64) {
                let result = total.addingReportingOverflow(value)
                if value < 0 || result.overflow {
                    total = Int64.max; arithmeticOverflow = true
                } else { total = result.partialValue }
            }
            var identities = Set<StorageFileIdentity>()
            for record in records {
                if record.hasRecognizedPhysicalEvidence { summary.recognizedPhysicalEvidenceCount += 1 }
                if record.currentReferenceState == .unknown { summary.currentReferenceUnknownCount += 1 }
                if record.currentReferenceState == .active { summary.currentReferenceActiveCount += 1 }
                if [.differentLocationHasDisk, .differentLocationMissingDisk, .differentLocationUnmeasured].contains(record.holdPathState) {
                    summary.differentHoldLocationCount += 1
                }
                if record.baseComparison == .differs { summary.baseDriftCount += 1 }
                if record.isReviewableForBytePreservingMaintenance { summary.reviewableCount += 1 }
                guard record.diskState == .present, let identity = record.reviewSnapshot.diskIdentity else {
                    summary.allocationUnknownCount += 1; summary.privateUnknownCount += 1; continue
                }
                if identity.linkCount != 1 { summary.linkedDiskCount += 1 }
                guard identities.insert(StorageFileIdentity(device: identity.device, inode: identity.inode)).inserted else { continue }
                add(identity.logicalBytes, to: &summary.logicalBytes)
                if let allocated = identity.allocatedBytes { add(allocated, to: &summary.allocatedBytesBeforeSharingReconciliation) }
                else { summary.allocationUnknownCount += 1 }
                if let measured = record.privateBytes { add(measured, to: &summary.privateBytesObserved) }
                else { summary.privateUnknownCount += 1 }
            }
            summary.arithmeticOverflow = arithmeticOverflow
            if arithmeticOverflow {
                budget.stop("aggregateOverflow"); summary.isPartial = true; summary.reviewableCount = 0
                for index in records.indices where !records[index].planningBlockers.contains(.inventoryIncomplete) {
                    records[index].planningBlockers.append(.inventoryIncomplete)
                }
            }
            return LegacyRecoveryInventoryReport(
                capturedAt: capturedAt, rootIdentity: rootIdentity, rootDiagnostic: rootDiagnostic,
                directoryEntriesVisited: budget.entries, sidecarReadsAttempted: budget.reads,
                sidecarBytesRead: budget.bytes, diskContentBytesRead: 0,
                stopReasons: budget.reasons, records: records, summary: summary)
        }

        func referenceState(_ environmentID: String?, now: Date) -> LegacyRecoveryReferenceState {
            guard let id = environmentID?.lowercased(), let references = request.currentReferences else { return .unknown }
            // Positive evidence stays protective even if the snapshot is stale.
            if references.activeEnvironmentIDs.contains(id) { return .active }
            if references.referencedEnvironmentIDs.contains(id) { return .referenced }
            let age = now.timeIntervalSince(references.capturedAt)
            guard references.isComplete, age >= 0, age <= request.limits.maximumReferenceAge else { return .unknown }
            return .unreferenced
        }
        func addReferenceBlocker(_ value: LegacyRecoveryReferenceState,
                                 to blockers: inout [LegacyRecoveryPlanningBlocker]) {
            let blocker: LegacyRecoveryPlanningBlocker?
            switch value {
            case .unknown: blocker = .currentReferencesUnknown
            case .active: blocker = .currentReferenceActive
            case .referenced: blocker = .currentReferenceExists
            case .unreferenced: blocker = nil
            }
            if let blocker, !blockers.contains(blocker) { blockers.append(blocker) }
        }

        func inspectDisk(_ rootFD: Int32, _ components: [String]) -> DiskRead {
            guard budget.check() else { return DiskRead(state: .budgetExceeded) }
            let fd = LegacyRecoveryInventory.openFile(rootFD, components)
            guard fd >= 0 else { return DiskRead(state: LegacyRecoveryInventory.failureState(errno)) }
            defer { close(fd) }
            guard let before = LegacyRecoveryInventory.identity(fd) else { return DiskRead(state: .unreadable) }
            guard LegacyRecoveryInventory.isRegular(before) else { return DiskRead(state: .notRegularFile, identity: before) }
            let clone: StorageCloneAttributes?
            if case .attributes(let attributes) = seams.cloneAttributes(fd) { clone = attributes }
            else { clone = nil }
            let backup: LegacyRecoveryAttributePresence
            let result = fgetxattr(fd, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0)
            if result >= 0 { backup = .present }
            else if errno == ENOATTR { backup = .absent }
            else { backup = .unknown }
            guard LegacyRecoveryInventory.identity(fd) == before,
                  matchesPathIdentity(rootFD, components, before) else {
                return DiskRead(state: .changedDuringRead, identity: before)
            }
            return DiskRead(state: .present, identity: before, attributes: clone, backup: backup)
        }

        func readSmall(_ rootFD: Int32, _ components: [String]) -> SmallRead {
            guard budget.beginRead() else { return small(.budgetExceeded) }
            let fd = LegacyRecoveryInventory.openFile(rootFD, components)
            guard fd >= 0 else { return small(LegacyRecoveryInventory.failureState(errno)) }
            defer { close(fd) }
            guard let before = LegacyRecoveryInventory.identity(fd) else { return small(.unreadable) }
            guard LegacyRecoveryInventory.isRegular(before) else { return small(.notRegularFile, identity: before) }
            guard before.logicalBytes >= 0, before.logicalBytes <= Int64(request.limits.maximumSidecarBytes) else {
                return small(.tooLarge, identity: before)
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: min(4096, request.limits.maximumSidecarBytes))
            while data.count < Int(before.logicalBytes) {
                guard budget.check() else { return small(.budgetExceeded, identity: before) }
                let wanted = min(buffer.count, Int(before.logicalBytes) - data.count)
                guard wanted <= request.limits.maximumTotalSidecarBytes - budget.bytes else {
                    budget.stop("sidecarByteBudget"); return small(.budgetExceeded, identity: before)
                }
                let count = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, wanted) }
                if count < 0 {
                    if errno == EINTR { continue }
                    return small(.unreadable, identity: before)
                }
                guard count > 0 else { return small(.changedDuringRead, identity: before) }
                guard budget.acceptBytes(count) else { return small(.budgetExceeded, identity: before) }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard LegacyRecoveryInventory.identity(fd) == before,
                  matchesPathIdentity(rootFD, components, before) else { return small(.changedDuringRead, identity: before) }
            return SmallRead(observation: LegacyRecoverySidecarObservation(
                state: .present, identity: before, sha256: FloeDigest.sha256Hex(data)), data: data)
        }
        func decode<T: Decodable>(_ type: T.Type, read: inout SmallRead) -> T? {
            guard let data = read.data else { return nil }
            do { return try JSONDecoder().decode(type, from: data) }
            catch { read.observation.state = .malformed; return nil }
        }
        func small(_ state: LegacyRecoveryObservationState,
                   identity: LegacyRecoveryFileIdentity? = nil) -> SmallRead {
            SmallRead(observation: LegacyRecoverySidecarObservation(state: state, identity: identity, sha256: nil), data: nil)
        }
        func notRequested() -> SmallRead { small(.notRequested) }
        func matchesPathIdentity(_ rootFD: Int32, _ components: [String],
                                 _ expected: LegacyRecoveryFileIdentity) -> Bool {
            let fd = LegacyRecoveryInventory.openFile(rootFD, components)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            return LegacyRecoveryInventory.identity(fd) == expected
        }
    }

    static func supportedRuntimeID(parent: [String], name: String) -> String? {
        if parent == ["runtime", "vm"] { return safeID(name, .runtime) ? name : nil }
        guard parent == ["recovery", "quarantine"], name.hasPrefix("runtime-vm-"), name.utf8.count <= 240,
              name.count > "runtime-vm-".count + 37 else { return nil }
        let suffix = String(name.suffix(36))
        guard UUID(uuidString: suffix) != nil, name.dropLast(36).last == "-" else { return nil }
        let runtime = String(name.dropFirst("runtime-vm-".count).dropLast(37))
        return safeID(runtime, .runtime) ? runtime : nil
    }
    static func supportedPreservedPath(_ path: String) -> [String]? {
        guard !path.hasPrefix("/"), path.utf8.count <= 512 else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy(safeComponent), let last = parts.last,
              supportedRuntimeID(parent: Array(parts.dropLast()), name: last) != nil else { return nil }
        return parts
    }
    static func safeID(_ value: String, _ kind: RuntimeV2Identifier.Kind) -> Bool {
        (try? RuntimeV2Identifier.validate(value, kind: kind)) != nil
    }
    static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.utf8.contains(0) && value.utf8.count <= 255
    }
    static func validSHA512(_ value: String) -> Bool {
        value.utf8.count == 128 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    struct OpenedRoot {
        let descriptor: Int32
        let diagnostic: LegacyRecoveryRootDiagnostic?
    }
    static func openCanonicalDirectory(_ path: String) -> OpenedRoot {
        func failure(_ stage: LegacyRecoveryRootDiagnostic.Stage, _ code: Int32,
                     _ index: Int? = nil) -> OpenedRoot {
            errno = code
            return OpenedRoot(descriptor: -1,
                diagnostic: .init(stage: stage, posixErrno: code, componentIndex: index))
        }
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else {
            return failure(.inputValidation, EINVAL)
        }
        guard path.split(separator: "/").allSatisfy({ safeComponent(String($0)) }) else {
            return failure(.inputValidation, EINVAL)
        }
        // Trust applies only to this service-supplied root, which must already
        // exist. This does not create it or canonicalize any controlled child.
        guard let resolved = path.withCString({ realpath($0, nil) }) else {
            let code = errno
            return failure(.posixCanonicalization, code)
        }
        defer { free(resolved) }
        guard let canonical = String(validatingUTF8: resolved), canonical.hasPrefix("/"),
              canonical.utf8.count <= 4096 else { return failure(.posixCanonicalization, EINVAL) }
        let parts = canonical.split(separator: "/").map(String.init)
        guard parts.allSatisfy(safeComponent) else { return failure(.inputValidation, EINVAL) }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            return failure(.filesystemRootOpen, code)
        }
        for (index, part) in parts.enumerated() {
            let next = part.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            let code = errno; close(descriptor)
            guard next >= 0 else { return failure(.componentOpen, code, index) }
            descriptor = next
        }
        return OpenedRoot(descriptor: descriptor, diagnostic: nil)
    }
    static func openDirectory(_ rootFD: Int32, _ components: [String]) -> Int32 {
        guard components.allSatisfy(safeComponent) else { errno = EINVAL; return -1 }
        var descriptor = dup(rootFD)
        guard descriptor >= 0 else { return -1 }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        for part in components {
            let next = openat(descriptor, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = errno; close(descriptor)
            guard next >= 0 else { errno = error; return -1 }
            descriptor = next
        }
        return descriptor
    }
    static func openFile(_ rootFD: Int32, _ components: [String]) -> Int32 {
        guard let last = components.last, safeComponent(last) else { errno = EINVAL; return -1 }
        let parent = openDirectory(rootFD, Array(components.dropLast()))
        guard parent >= 0 else { return -1 }
        let result = openat(parent, last, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        let error = errno; close(parent); errno = error
        return result
    }
    static func failureState(_ error: Int32) -> LegacyRecoveryObservationState {
        switch error {
        case ENOENT: return .missing
        case ELOOP, ENOTDIR, EINVAL: return .symlinkOrUnsafePath
        default: return .unreadable
        }
    }
    static func identity(_ descriptor: Int32) -> LegacyRecoveryFileIdentity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        let multiplied = Int64(info.st_blocks).multipliedReportingOverflow(by: 512)
        return LegacyRecoveryFileIdentity(
            device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino),
            logicalBytes: Int64(info.st_size),
            allocatedBytes: multiplied.overflow || multiplied.partialValue < 0 ? nil : multiplied.partialValue,
            linkCount: UInt64(info.st_nlink), mode: UInt32(info.st_mode),
            modification: LegacyRecoveryTimestamp(seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec)),
            change: LegacyRecoveryTimestamp(seconds: Int64(info.st_ctimespec.tv_sec), nanoseconds: Int64(info.st_ctimespec.tv_nsec)))
    }
    static func isRegular(_ identity: LegacyRecoveryFileIdentity) -> Bool {
        identity.mode & UInt32(S_IFMT) == UInt32(S_IFREG)
    }
}
#endif
