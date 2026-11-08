// Exercises the production request coordinator with injected native availability.
// Synthetic PNGs validate lifecycle/bytes only; these are not Apple generations.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private struct CheckFailure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message: message) }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

@main
struct ImagePlaygroundContractTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-image-playground-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("synthetic.png")
        let bytes = try png()
        try bytes.write(to: imageURL)
        let image = try AppleImagePlaygroundImage(contentsOf: imageURL)
        try check(image.data == bytes && image.width == 3 && image.height == 2, "Original encoding/dimensions changed")
        try check(image.fileExtension == "png" && image.mimeType == "image/png" && image.sha256.count == 64,
                  "Result identity is incomplete")
        do { _ = try AppleImagePlaygroundImage(data: Data("invalid".utf8)); throw CheckFailure(message: "Invalid bytes accepted") }
        catch AppleImagePlaygroundFailure.invalidImage { }
        do { _ = try AppleImagePlaygroundImage(data: Data(repeating: 0, count: AppleImagePlaygroundImage.maximumBytes + 1)); throw CheckFailure(message: "Oversized bytes accepted") }
        catch AppleImagePlaygroundFailure.invalidImage { }
        print("PASS encoded image validation, exact bytes and actual format")

        let owner = AppleImagePlaygroundOwner(conversationID: UUID(), runID: UUID(), toolCallID: "synthetic-call")
        let input = AppleImagePlaygroundInput(prompt: "a synthetic test scene")
        do { try AppleImagePlaygroundInput(prompt: " ").validate(); throw CheckFailure(message: "Empty prompt accepted") }
        catch AppleImagePlaygroundFailure.invalidInput { }
        do { try AppleImagePlaygroundInput(prompt: "edit", intent: .edit).validate(); throw CheckFailure(message: "Edit without original accepted") }
        catch AppleImagePlaygroundFailure.invalidInput { }
        do { try AppleImagePlaygroundInput(prompt: "test", width: 512).validate(); throw CheckFailure(message: "Partial dimensions accepted") }
        catch AppleImagePlaygroundFailure.invalidInput { }
        print("PASS request validation")

        let unavailable = service(available: false)
        await expect(.unavailable) { try await unavailable.request(input, owner: owner, isCancelled: { false }) }
        let noHost = service()
        await expect(.foregroundRequired) { try await noHost.request(input, owner: owner, isCancelled: { false }) }
        noHost.updateHost(sceneID: "other", visibleConversationIDs: [UUID()], active: true)
        await expect(.foregroundRequired) { try await noHost.request(input, owner: owner, isCancelled: { false }) }
        noHost.updateHost(sceneID: "one", visibleConversationIDs: [owner.conversationID], active: true)
        noHost.updateHost(sceneID: "two", visibleConversationIDs: [owner.conversationID], active: true)
        await expect(.foregroundRequired) { try await noHost.request(input, owner: owner, isCancelled: { false }) }
        print("PASS unavailable, missing, foreign and ambiguous foreground hosts")

        let covered = service()
        var coveredByAnotherSurface = true
        covered.updateHost(sceneID: "covered", visibleConversationIDs: [owner.conversationID], active: true,
                           canPresent: { !coveredByAnotherSurface })
        await expect(.foregroundRequired) { try await covered.request(input, owner: owner, isCancelled: { false }) }
        coveredByAnotherSurface = false
        let uncovered = Task { try await covered.request(input, owner: owner, isCancelled: { false }) }
        let uncoveredID = try await waitForPresentation(covered)
        covered.fail(id: uncoveredID, error: .cancelled)
        await expect(.cancelled) { try await uncovered.value }
        print("PASS presentability is checked live and a covered active chat cannot present")

        let success = service()
        success.updateHost(sceneID: "one", visibleConversationIDs: [owner.conversationID], active: true)
        let first = Task { try await success.request(input, owner: owner, isCancelled: { false }) }
        let firstID = try await waitForPresentation(success)
        try check(success.beginPresentation(id: firstID), "The current request could not mount")
        success.receive(id: UUID(), imageURL: imageURL)
        try check(success.presentation?.id == firstID, "A foreign callback settled the request")
        await expect(.busy) { try await success.request(input, owner: owner, isCancelled: { false }) }
        success.receive(id: firstID, imageURL: imageURL)
        let returned = try await first.value
        try check(returned.data == bytes && success.presentation == nil, "Completed image was not frozen")
        try FileManager.default.removeItem(at: imageURL)
        try check(returned.data == bytes, "Result depended on a deleted system temporary file")
        success.receive(id: firstID, imageURL: imageURL)
        await expect(.busy) { try await success.request(input, owner: owner, isCancelled: { false }) }
        success.didDismiss(id: firstID)
        try bytes.write(to: imageURL)
        print("PASS completion, temporary URL lifetime, duplicate/foreign callback and dismissal fencing")

        let second = Task { try await success.request(input, owner: owner, isCancelled: { false }) }
        let secondID = try await waitForPresentation(success)
        try check(success.beginPresentation(id: secondID), "The second request could not mount")
        success.didDismiss(id: firstID)
        try check(success.presentation?.id == secondID, "Late dismissal affected the new request")
        success.updateHost(sceneID: "one", visibleConversationIDs: [owner.conversationID], active: false)
        try check(success.presentation?.id == secondID, "Background transition was treated as navigation")
        success.updateHost(sceneID: "one", visibleConversationIDs: [UUID()], active: true)
        await expect(.ownerChanged) { try await second.value }
        success.receive(id: secondID, imageURL: imageURL)
        success.didDismiss(id: secondID)
        print("PASS background preservation and navigation cancellation")

        success.updateHost(sceneID: "one", visibleConversationIDs: [owner.conversationID], active: true)
        let cancelled = Task { try await success.request(input, owner: owner, isCancelled: { false }) }
        let cancelledID = try await waitForPresentation(success)
        try check(success.beginPresentation(id: cancelledID), "The cancellable request could not mount")
        cancelled.cancel()
        // Deliberately race the callback against the actor's cancellation handler.
        success.receive(id: cancelledID, imageURL: imageURL)
        await expect(.cancelled) { try await cancelled.value }
        success.didDismiss(id: cancelledID)
        let token = CancellationFlag()
        let tokenTask = Task { try await success.request(input, owner: owner, isCancelled: { token.cancelled }) }
        let tokenID = try await waitForPresentation(success)
        try check(success.beginPresentation(id: tokenID), "The token request could not mount")
        token.cancel()
        await expect(.cancelled) { try await tokenTask.value }
        success.receive(id: tokenID, imageURL: imageURL)
        success.didDismiss(id: tokenID)
        print("PASS Swift task and runtime-token cancellation, including callback race")

        let unmounted = Task { try await success.request(input, owner: owner, isCancelled: { false }) }
        let unmountedID = try await waitForPresentation(success)
        unmounted.cancel()
        await expect(.cancelled) { try await unmounted.value }
        try check(!success.beginPresentation(id: unmountedID), "A cancelled request mounted late")
        // No native controller existed, so there will be no onDismiss callback.
        let retry = Task { try await success.request(input, owner: owner, isCancelled: { false }) }
        let retryID = try await waitForPresentation(success)
        success.didDismiss(id: unmountedID)
        try check(success.presentation?.id == retryID, "Late unmounted dismissal cancelled the retry")
        success.fail(id: retryID, error: .cancelled)
        await expect(.cancelled) { try await retry.value }
        print("PASS cancellation before native mount permits retry without a dismissal callback")

        var live = true
        let expired = AppleImagePlaygroundService(enabled: { true }, ownerIsLive: { _ in live }, available: { true })
        expired.updateHost(sceneID: "one", visibleConversationIDs: [owner.conversationID], active: true)
        let expiredTask = Task { try await expired.request(input, owner: owner, isCancelled: { false }) }
        let expiredID = try await waitForPresentation(expired)
        live = false
        expired.receive(id: expiredID, imageURL: imageURL)
        await expect(.ownerChanged) { try await expiredTask.value }
        expired.didDismiss(id: expiredID)
        let oldSystem = AppleImagePlaygroundService(enabled: { true }, ownerIsLive: { _ in true },
            available: { true }, supportsEditing: { false })
        oldSystem.updateHost(sceneID: "one", visibleConversationIDs: [owner.conversationID], active: true)
        await expect(.editingUnavailable) {
            try await oldSystem.request(AppleImagePlaygroundInput(prompt: "edit", source: image, intent: .edit),
                                        owner: owner, isCancelled: { false })
        }
        print("PASS dead run and legacy-system editing limits")
        print("ImagePlayground contract checks passed; Apple inference and full App UI were not exercised.")
    }

    @MainActor private static func service(available: Bool = true) -> AppleImagePlaygroundService {
        AppleImagePlaygroundService(enabled: { true }, ownerIsLive: { _ in true }, available: { available })
    }

    @MainActor private static func expect(
        _ expected: AppleImagePlaygroundFailure,
        _ action: () async throws -> AppleImagePlaygroundImage
    ) async {
        do { _ = try await action(); fatalError("Expected \(expected)") }
        catch { guard error as? AppleImagePlaygroundFailure == expected else { fatalError("Unexpected error: \(error)") } }
    }

    @MainActor private static func waitForPresentation(_ service: AppleImagePlaygroundService) async throws -> UUID {
        for _ in 0..<100 {
            if let id = service.presentation?.id { return id }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw CheckFailure(message: "Request did not reach the native presentation boundary")
    }

    private static func png() throws -> Data {
        guard let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
                bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              context.width == 3 else { throw CheckFailure(message: "PNG fixture context failed") }
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        guard let image = context.makeImage() else { throw CheckFailure(message: "PNG fixture image failed") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CheckFailure(message: "PNG fixture destination failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure(message: "PNG fixture encoding failed") }
        return data as Data
    }
}
