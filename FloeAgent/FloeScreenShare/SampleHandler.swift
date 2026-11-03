// FloeScreenShare — ReplayKit owns capture and final system consent.
import ReplayKit
import CoreMedia
import CoreImage
import UIKit
import FloeCore

/// ReplayKit serializes its callbacks. The independent stop timer also uses
/// this recursive lock; all mutable fields and CIContext access are guarded.
/// Recursive locking permits a synchronous finish callback without reentry
/// into a newer session between validating the command and invoking ReplayKit.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private let lock=NSRecursiveLock()
    private let imageContext=CIContext()
    private var state: ScreenShareSessionState?
    private var timer: DispatchSourceTimer?
    private var lastCapture=Date.distantPast
    private var lastHeartbeat=Date.distantPast
    private var pendingStop: ScreenShareStopCommand?
    private var finishInvoked=false
    private static var store: ScreenShareSharedStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"group.org.floeagent.ios")
            .map(ScreenShareSharedStore.init(container:))
    }
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock();defer{lock.unlock()};return body()
    }
    override func broadcastStarted(withSetupInfo setupInfo: [String:NSObject]?) {
        synchronized {
            timer?.cancel();timer=nil
            let fresh=ScreenShareSessionState(sessionID:UUID(),isActive:true,phase:.active)
            state=fresh;pendingStop=nil;finishInvoked=false;lastCapture = .distantPast;lastHeartbeat = .distantPast
            do {
                guard let store=Self.store else { throw ScreenShareSharedStore.Failure.invalid }
                try store.install(fresh)
                let timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"org.floeagent.screenshare.control"))
                timer.schedule(deadline:.now(),repeating:.milliseconds(250),leeway:.milliseconds(50))
                timer.setEventHandler { [weak self] in self?.controlTick() }
                self.timer=timer;timer.resume()
            } catch {
                finishInvoked=true
                finishBroadcastWithError(NSError(domain:"org.floeagent.screenshare",code:1,userInfo:[NSLocalizedDescriptionKey:
                    FloeL10n.isChinese ? "无法开始屏幕共享，请重试。" : "Screen sharing couldn’t start. Try again."]))
            }
        }
    }
    override func broadcastPaused() {
        synchronized {
            guard var value=state,!finishInvoked else{return}
            value.phase = .paused;value.updatedAt=Date();state=value;_ = try? Self.store?.update(value)
        }
    }
    override func broadcastResumed() {
        synchronized {
            guard var value=state,!finishInvoked else{return}
            value.phase = .active;value.updatedAt=Date();state=value;_ = try? Self.store?.update(value)
        }
    }
    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else{return}
        synchronized {
            guard var value=state,!finishInvoked,value.effectivePhase == .active,
                  Date().timeIntervalSince(lastCapture)>=1,let store=Self.store,
                  let pixels=CMSampleBufferGetImageBuffer(sampleBuffer) else{return}
            lastCapture=Date()
            var image=CIImage(cvPixelBuffer:pixels)
            if let orientation=CMGetAttachment(sampleBuffer,key:RPVideoSampleOrientationKey as CFString,attachmentModeOut:nil) as? NSNumber {
                image=image.oriented(forExifOrientation:orientation.int32Value)
            }
            guard let cg=imageContext.createCGImage(image,from:image.extent),
                  let bytes=UIImage(cgImage:cg).jpegData(compressionQuality:0.6) else{return}
            value.frameID=UUID();value.frameCapturedAt=Date();value.updatedAt=Date()
            do { try store.publishJPEG(bytes,state:value);state=value } catch { /* A busy/stale write publishes no frame. */ }
        }
    }
    /// Independent of frame callbacks, including pause and no-new-frame periods.
    private func controlTick() {
        synchronized {
            guard var value=state,let store=Self.store,
                  store.state()?.sessionID == value.sessionID else{return}
            if let command=store.command(for:value.sessionID),command.matches(value),pendingStop?.requestID != command.requestID {
                pendingStop=command;finishInvoked=true
                value.phase = .stopping;value.updatedAt=Date();state=value
                _ = try? store.update(value)
                // Public ReplayKit API. Do not acknowledge before invoking it.
                finishBroadcastWithError(NSError(domain:"org.floeagent.screenshare.stop",code:0,userInfo:[NSLocalizedDescriptionKey:
                    FloeL10n.isChinese ? "已停止屏幕共享。" : "Screen sharing stopped."]))
                try? store.acknowledge(.init(command:command,phase:.finishInvoked))
                store.removeFrames(for:value.sessionID)
                return
            }
            guard !finishInvoked,Date().timeIntervalSince(lastHeartbeat)>=1 else{return}
            lastHeartbeat=Date();value.updatedAt=Date();state=value
            _ = try? store.update(value) // Does not renew frameCapturedAt.
        }
    }
    override func broadcastFinished() {
        synchronized {
            timer?.cancel();timer=nil
            guard var value=state else{return}
            value.isActive=false;value.phase = .stopped;value.updatedAt=Date()
            _ = try? Self.store?.update(value) // CAS cannot overwrite a newer broadcast.
            if let command=pendingStop { try? Self.store?.acknowledge(.init(command:command,phase:.finished)) }
            Self.store?.removeFrames(for:value.sessionID)
            state=nil;pendingStop=nil;finishInvoked=true
        }
    }
}
