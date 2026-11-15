// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// The exact existing display generation the host attached for one game run.
/// `displayServiceID` is the local display owner's generation identity; it is
/// never a guest project path or a permission token.
public struct RGSSGuestDisplayRequest: Sendable, Equatable {
    public let context: GameProjectContext
    public let environmentID: String
    public let workspaceRoot: URL
    public let displayServiceID: String

    public init(context: GameProjectContext, environmentID: String,
                workspaceRoot: URL, displayServiceID: String) throws {
        guard let contextEnvironment = context.environmentID,
              contextEnvironment == environmentID,
              !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RGSSGuestRunError.missingEnvironment
        }
        guard workspaceRoot.isFileURL else {
            throw RGSSGuestRunError.displayUnavailable("workspace root is not a file URL")
        }
        guard !displayServiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RGSSGuestRunError.displayUnavailable("display generation identity")
        }
        self.context = context
        self.environmentID = environmentID
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.displayServiceID = displayServiceID
    }

    public var conversationID: UUID? {
        if case .conversation(let conversationID, _) = context.owner { return conversationID }
        return nil
    }
}

/// One attached display/input generation. `detachViewer` releases only the
/// client transport/view demand; the owned display service and the game job
/// keep running. An explicit stop path is separate and remains owned by the
/// App's existing `LocalLinuxDisplayOwner`.
public struct RGSSGuestDisplayAttachment: Sendable {
    public let environmentID: String
    public let displayServiceID: String
    /// The exact guest X display (for example `:0`) the launcher resolved.
    public let guestDisplay: String
    public let inputPort: any RGSSGuestPhysicalInputPort
    /// Bounded JPEG capture from the existing VNC session. Nil is honest when
    /// the framebuffer is not ready; it is not a synthetic black image.
    public let captureScreenshot: @Sendable () async throws -> Data?
    /// Releases this viewer's client demand. Never stops the guest service.
    public let detachViewer: @Sendable () async -> Void

    public init(
        environmentID: String,
        displayServiceID: String,
        guestDisplay: String,
        inputPort: any RGSSGuestPhysicalInputPort,
        captureScreenshot: @escaping @Sendable () async throws -> Data?,
        detachViewer: @escaping @Sendable () async -> Void
    ) throws {
        guard !environmentID.isEmpty, !displayServiceID.isEmpty,
              guestDisplay.range(of: #"^:[0-9]{1,2}(\.[0-9]+)?$"#,
                                 options: .regularExpression) != nil else {
            throw RGSSGuestRunError.displayUnavailable("invalid display attachment")
        }
        self.environmentID = environmentID
        self.displayServiceID = displayServiceID
        self.guestDisplay = guestDisplay
        self.inputPort = inputPort
        self.captureScreenshot = captureScreenshot
        self.detachViewer = detachViewer
    }
}

/// Implemented by the App over the existing `LocalLinuxDisplayCenter/Owner`.
/// The implementation must resolve the same conversation/workspace owner and
/// environment that the project context carries; it must never create a second
/// display service or choose another environment.
public protocol RGSSGuestDisplayProviding: Sendable {
    func attach(_ request: RGSSGuestDisplayRequest) async throws -> RGSSGuestDisplayAttachment
    func detach(_ attachment: RGSSGuestDisplayAttachment) async
}

/// A fail-closed display provider used only in tests or when the App has not
/// wired the local screen yet. It never fabricates a session.
public struct RGSSGuestUnavailableDisplayProvider: RGSSGuestDisplayProviding {
    public init() {}
    public func attach(_ request: RGSSGuestDisplayRequest) async throws -> RGSSGuestDisplayAttachment {
        throw RGSSGuestRunError.displayUnavailable(
            "Open the local Linux screen for this task before starting an RPG Maker game.")
    }
    public func detach(_ attachment: RGSSGuestDisplayAttachment) async {}
}
