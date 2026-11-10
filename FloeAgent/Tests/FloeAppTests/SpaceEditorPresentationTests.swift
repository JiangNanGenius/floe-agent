// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import SwiftUI
import FloeCore
@testable import FloeApp

@Suite("Library editor input handoff")
@MainActor struct SpaceEditorPresentationTests {
    private func input() -> SpaceEditorInputReadiness {
        .init(activeWindow: true, searching: false, searchFirstResponder: false, keyboardTransition: false,
              windowBounds: CGRect(x: 0, y: 0, width: 1133, height: 744),
              keyboardFrame: CGRect(x: 0, y: 724, width: 1133, height: 20), bottomSafeArea: 20, pixel: 0.5,
              layoutCurrent: true, sourceFrame: CGRect(x: 280, y: 137.5, width: 853, height: 586.5),
              sourceSafeAreaBottom: 20, nativeContentBottom: 724, nativeHostBottom: 744, nativeSafeAreaBottom: 20)
    }
    @Test func focusLossAloneCannotPresentWhileSearchInteractionOrResponderIsActive() {
        var state = input(); state.searching = true
        #expect(!state.canPresent)
        state.searching = false; state.searchFirstResponder = true
        #expect(!state.canPresent)
        state.searchFirstResponder = false
        #expect(state.canPresent)
    }
    @Test func theObservedShortViewportWaitsForActualKeyboardGeometryAndItsCompletedTransition() {
        var state = input()
        state.keyboardFrame = CGRect(x: 0, y: 387.5, width: 1133, height: 356.5)
        #expect(!state.canPresent)
        state.keyboardFrame = CGRect(x: 0, y: 724, width: 1133, height: 20)
        state.keyboardTransition = true
        #expect(!state.canPresent)
        state.keyboardTransition = false
        #expect(state.canPresent)
    }
    @Test func hardwareKeyboardAndDifferentWindowSizesNeedNoFixedDelayOrHeight() {
        var state = input(); state.keyboardFrame = .zero
        #expect(state.canPresent)
        state.windowBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        state.bottomSafeArea = 34; state.keyboardFrame = CGRect(x: 0, y: 810, width: 390, height: 34)
        state.layoutCurrent = false
        #expect(!state.canPresent)
        state.sourceFrame = CGRect(x: 0, y: 140, width: 390, height: 670)
        state.sourceSafeAreaBottom = 34; state.nativeSafeAreaBottom = 34; state.nativeContentBottom = 810; state.nativeHostBottom = 844
        state.layoutCurrent = true
        #expect(state.canPresent)
        state.activeWindow = false
        #expect(!state.canPresent)
    }
    @Test func hiddenKeyboardNotificationAndZeroGuideCannotOverrideAStaleSwiftUIProposal() {
        var state = input(); state.keyboardFrame = .zero
        state.sourceSafeAreaBottom = 389
        state.sourceFrame.size.height = 269
        #expect(!state.canPresent)
        state.sourceSafeAreaBottom = 20
        #expect(!state.canPresent)
        state.sourceFrame = .zero
        #expect(!state.canPresent)
        state = input(); state.sourceSafeAreaBottom = .nan
        #expect(!state.canPresent)
        state = input(); state.layoutCurrent = false
        #expect(!state.canPresent)
        state = input(); state.sourceFrame.size.height = 606.5 // Extending through the native bottom inset is also valid.
        #expect(state.canPresent)
    }
    @Test func realWindowMeasurementsExpireOnResizeOrSourceHostReplacement() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = UIViewController(); window.rootViewController = host
        host.view.frame = window.bounds; window.addSubview(host.view)
        let probe = SpaceLibraryInputProbe.Probe(frame: window.bounds)
        host.view.addSubview(probe)
        defer { probe.stop(); probe.removeFromSuperview(); window.rootViewController = nil }
        probe.update(nil, searching: false, geometrySize: probe.bounds.size, safeAreaBottom: 0, onReady: { _ in })
        #expect(probe.input()?.layoutCurrent == false)
        probe.layoutIfNeeded()
        #expect(probe.input()?.layoutCurrent == true)
        window.bounds.size.width = 900
        #expect(probe.input()?.layoutCurrent == false)
        let replacement = UIViewController(); window.rootViewController = replacement
        replacement.view.frame = window.bounds; window.addSubview(replacement.view)
        replacement.view.addSubview(probe)
        #expect(probe.input()?.layoutCurrent == false)
        probe.frame = window.bounds
        probe.update(nil, searching: false, geometrySize: probe.bounds.size, safeAreaBottom: 0, onReady: { _ in })
        probe.layoutIfNeeded()
        #expect(probe.input()?.layoutCurrent == true)
    }
    @Test func anOldOrCancelledRequestCannotPresentAndAClaimIsDeliveredOnlyOnce() {
        let first = UUID(), next = UUID(); var state = SpaceEditorInputClaim()
        state.setRequest(first)
        #expect(state.claim(input()) == first)
        #expect(state.claim(input()) == nil)
        state.setRequest(next)
        #expect(!state.owns(first))
        #expect(state.claim(input()) == next)
        state.setRequest(nil)
        #expect(!state.owns(next) && state.claim(input()) == nil)
    }
}

/// Only the owner/presentation/retry boundary; engine rendering is verified by
/// the separate real App Word workflow. Every original here has an isolated
/// existing PersonalContentService root and a generated exact record UUID.
#if DEBUG
@Suite("Personal Office owner lifecycle", .serialized)
@MainActor struct PersonalOfficeOwnerLifecycleTests {
    private func fixture() async throws -> (root: URL, owner: PersonalOfficeDocument) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("office326-owner-" + UUID().uuidString, isDirectory: true)
        let service = PersonalContentService(root: root)
        let record = try await service.createDocument(format: .word, title: "QA Office owner", id: UUID())
        let location = try await service.library().resolve(record.id)
        let original = try await service.originalFile(record.id)
        let owner = try await PersonalOfficeDocument.open(record: record, directory: location.url,
                                                         url: original, contentService: service)
        let receipt: [String: String] = ["recordID": record.id.uuidString, "original": original.path,
            "sha256": try FloeDigest.sha256Hex(ofFileAt: original), "purpose": "isolated-owner-lifecycle-fixture"]
        print("FLOE_QA_OFFICE_OWNER_FIXTURE|" + String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys), as: UTF8.self))
        return (root, owner)
    }

    @Test("A temporary full-screen cover retains the owner; true close invalidates the old open")
    func temporaryCoverAndTrueClose() async throws {
        let environment = try await appQualificationEnvironment()
        let fixture = try await fixture(), owner = fixture.owner
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: PersonalOfficeDocumentView(document: owner,
            onClose: {}, onAssistant: {}, presentationIsActive: true, onRetryOpen: {})
            .environmentObject(environment))
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        do {
            let deadline = Date().addingTimeInterval(5)
            while owner.session.phase == .idle, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
            #expect(owner.session.phase != .idle)
            let cover = UIViewController(); cover.modalPresentationStyle = .fullScreen
            host.present(cover, animated: false)
            try await Task.sleep(for: .milliseconds(250))
            #expect(host.presentedViewController === cover)
            #expect(await owner.start(environment: environment))
            do { try PersonalOfficeDocument.requireClosedForFileAction(projectID: owner.record.id); Issue.record("Covered editor lost its file-action ownership") }
            catch { #expect(error is PersonalFileActionError) }
            cover.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(100))
            #expect(await owner.start(environment: environment))
            #expect(await owner.close())
            #expect(owner.session.phase == .idle && owner.session.controller == nil)
            #expect(!(await owner.start(environment: environment)), "A closed owner cannot mount again")
            try await Task.sleep(for: .milliseconds(100))
            #expect(owner.session.phase == .idle && owner.session.controller == nil,
                    "The cancelled generation cannot mount or publish a late ready")
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: owner.record.id)
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            _ = await owner.close()
            throw error
        }
    }

    @Test("A pre-mount recovery resolves the same original into a fresh owner and remains retryable after failure")
    func retryResolvesSameOriginal() async throws {
        let environment = try await appQualificationEnvironment()
        let fixture = try await fixture(), owner = fixture.owner
        let original = owner.url, digest = try FloeDigest.sha256Hex(ofFileAt: original)
        let held = fixture.root.appendingPathComponent("held-original.docx")
        var replacement: PersonalOfficeDocument?
        do {
            try FileManager.default.moveItem(at: original, to: held)
            #expect(await owner.start(environment: environment))
            #expect(owner.session.phase == .failed && owner.session.controller == nil)
            #expect(await owner.session.recoverFailedSession())
            #expect(owner.session.phase == .idle)
            do {
                _ = try await owner.replacement()
                Issue.record("Missing original must never manufacture a successful reopen")
            } catch { owner.session.reportOpenFailure(error) }
            #expect(owner.session.phase == .failed && owner.session.canRecoverFailedSession)
            try FileManager.default.moveItem(at: held, to: original)
            let next = try await owner.replacement(); replacement = next
            #expect(next !== owner && next.record.id == owner.record.id)
            #expect(next.directory == owner.directory && next.url == original)
            #expect(try FloeDigest.sha256Hex(ofFileAt: next.url) == digest)
            #expect(owner.session.phase == .idle && owner.session.controller == nil)
            #expect(await next.close())
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            if FileManager.default.fileExists(atPath: held.path) { try? FileManager.default.moveItem(at: held, to: original) }
            if let replacement { _ = await replacement.close() }
            _ = await owner.close()
            throw error
        }
    }
}
#endif
#endif
