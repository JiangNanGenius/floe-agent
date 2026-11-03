import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Small App Group protocol, shared by host and upload extension. Writes use
/// a short nonblocking process lock; never hold it across ReplayKit/model I/O.
/// Session/UUID filenames cannot be supplied by a model or traverse paths.
public struct ScreenShareSharedStore: Sendable {
    public enum Failure: Error { case busy, invalid, staleSession }
    public let root: URL
    public init(container: URL) { root=container.appendingPathComponent("ScreenFrames",isDirectory:true) }
    private var stateURL: URL { root.appendingPathComponent("session.json") }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString,isDirectory:true) }
    public func frameURL(sessionID: UUID, frameID: UUID) -> URL {
        directory(sessionID).appendingPathComponent("frame-\(frameID.uuidString).jpg")
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL, cap: Int = 16384) -> T? {
        guard let size=try? url.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]),
              size.isSymbolicLink != true, let count=size.fileSize, count > 0,count <= cap,
              let data=try? Data(contentsOf:url) else { return nil }
        return try? JSONDecoder().decode(type,from:data)
    }
    public func state() -> ScreenShareSessionState? { read(ScreenShareSessionState.self,at:stateURL) }
    public func command(for id: UUID) -> ScreenShareStopCommand? {
        read(ScreenShareStopCommand.self,at:directory(id).appendingPathComponent("stop.json"))
    }
    public func acknowledgment(for id: UUID) -> ScreenShareStopAcknowledgment? {
        read(ScreenShareStopAcknowledgment.self,at:directory(id).appendingPathComponent("stop-ack.json"))
    }
    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:url,options:.atomic)
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let fd=open(root.appendingPathComponent("control.lock").path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,S_IRUSR|S_IWUSR)
        guard fd >= 0 else { throw Failure.invalid }; defer { close(fd) }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw Failure.busy }
        defer { _ = flock(fd,LOCK_UN) }
        return try operation()
    }
    public func install(_ state: ScreenShareSessionState) throws {
        try locked {
            let previous=self.state()?.sessionID
            try write(state,at:stateURL)
            if let previous,previous != state.sessionID {removeFrames(for:previous)}
            // Version 1 used this one bare frame; version 2 never does.
            try? FileManager.default.removeItem(at:root.appendingPathComponent("latest.jpg"))
        }
    }
    /// An old finish/heartbeat is never allowed to replace a newer session.
    @discardableResult public func update(_ value: ScreenShareSessionState) throws -> Bool {
        try locked {
            guard state()?.sessionID == value.sessionID else { return false }
            try write(value,at:stateURL); return true
        }
    }
    @discardableResult public func requestStop(_ value: ScreenShareStopCommand) throws -> Bool {
        try locked {
            guard let current=state(),value.matches(current) else { return false }
            try write(value,at:directory(value.sessionID).appendingPathComponent("stop.json")); return true
        }
    }
    public func acknowledge(_ value: ScreenShareStopAcknowledgment) throws {
        try locked {
            let url=directory(value.sessionID).appendingPathComponent("stop-ack.json")
            if let previous=acknowledgment(for:value.sessionID), previous.requestID == value.requestID,
               previous.phase.rawValue > value.phase.rawValue { return }
            try write(value,at:url)
        }
    }
    public func publishJPEG(_ data: Data, state: ScreenShareSessionState) throws {
        guard !data.isEmpty,data.count <= 8*1024*1024,let frame=state.frameID,state.frameCapturedAt != nil else { throw Failure.invalid }
        try locked {
            guard let previous=self.state(),previous.sessionID == state.sessionID,
                  previous.isActive,previous.effectivePhase != .stopping else { throw Failure.staleSession }
            let destination=frameURL(sessionID:state.sessionID,frameID:frame)
            try FileManager.default.createDirectory(at:directory(state.sessionID),withIntermediateDirectories:true)
            try data.write(to:destination,options:.atomic)
            do { try write(state,at:stateURL) }
            catch { try? FileManager.default.removeItem(at:destination); throw error }
            if let old=previous.frameID,old != frame { try? FileManager.default.removeItem(at:frameURL(sessionID:state.sessionID,frameID:old)) }
        }
    }
    /// No bare latest.jpg fallback: the image must belong to the exact state.
    public func currentJPEG(now: Date = Date()) -> (ScreenShareSessionState,Data)? {
        guard let first=state(),first.isFresh(at:now),let frame=first.frameID else { return nil }
        let url=frameURL(sessionID:first.sessionID,frameID:frame)
        guard let attrs=try? url.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]),
              attrs.isSymbolicLink != true,let size=attrs.fileSize,size > 0,size <= 8*1024*1024,
              let data=try? Data(contentsOf:url), let second=state(),second.sessionID == first.sessionID,
              second.frameID == frame,second.isFresh(at:now) else { return nil }
        return (first,data)
    }
    /// Only this session's protocol-owned JPEGs. Commands/acks remain as stop
    /// evidence; never remove the root or another session's files.
    public func removeFrames(for id: UUID) {
        guard let files=try? FileManager.default.contentsOfDirectory(at:directory(id),includingPropertiesForKeys:[.isSymbolicLinkKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("frame-") && file.pathExtension == "jpg" {
            let raw=String(file.deletingPathExtension().lastPathComponent.dropFirst(6))
            guard UUID(uuidString:raw) != nil,(try? file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
            try? FileManager.default.removeItem(at:file)
        }
    }
}
