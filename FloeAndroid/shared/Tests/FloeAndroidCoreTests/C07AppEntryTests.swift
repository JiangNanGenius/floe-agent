// SPDX-License-Identifier: MPL-2.0
//
// C07 App-entry contract tests. Authored source, NOT RUN by this lane.
// They exercise only pure Foundation logic: no App, DB, network, provider,
// device, file grant or model call participates.
import XCTest
import Foundation
@testable import FloeAndroidCore

final class C07AppEntryTests: XCTestCase {
    private let taskID = UUID(uuidString: "2A9BB479-F614-473C-B8E4-008E2DFE8222")!
    private let scheduleID = UUID(uuidString: "6C3A1E44-3B8D-4AD1-9A1B-7A2F0D5E8C11")!

    // MARK: - Routes

    func testRoutesKeepTheirExactTarget() throws {
        XCTAssertEqual(try C07AppEntryRoute.parse("floe://new"), .newTask)
        XCTAssertEqual(
            try C07AppEntryRoute.parse("FLOE://TASK/\(taskID.uuidString)"),
            .task(taskID)
        )
        XCTAssertEqual(
            try C07AppEntryRoute.parse("floe://schedule/\(scheduleID.uuidString.lowercased())"),
            .schedule(scheduleID)
        )
        XCTAssertEqual(try C07AppEntryRoute.parse("floe://share"), .share(nil))
        XCTAssertEqual(
            try C07AppEntryRoute.parse("floe://share?intake=\(taskID.uuidString.lowercased())"),
            .share(taskID)
        )
    }

    func testCanonicalLinksRoundTrip() throws {
        XCTAssertEqual(C07AppEntryRoute.newTask.url.absoluteString, "floe://new")
        XCTAssertEqual(
            C07AppEntryRoute.task(taskID).url.absoluteString,
            "floe://task/\(taskID.uuidString.lowercased())"
        )
        XCTAssertEqual(
            C07AppEntryRoute.schedule(scheduleID).url.absoluteString,
            "floe://schedule/\(scheduleID.uuidString.lowercased())"
        )
        XCTAssertEqual(C07AppEntryRoute.share(nil).url.absoluteString, "floe://share")
        XCTAssertEqual(
            C07AppEntryRoute.share(taskID).url.absoluteString,
            "floe://share?intake=\(taskID.uuidString.lowercased())"
        )
        XCTAssertEqual(
            try C07AppEntryRoute.parse(C07AppEntryRoute.share(taskID).url.absoluteString),
            .share(taskID)
        )
    }

    func testHostileLinksCannotBecomeExecutionOrAmbiguousIntake() {
        let inputs = [
            "floe://run",
            "floe://execute",
            "floe://new?prompt=run&autoSend=true",
            "floe://new?permission=all",
            "floe://task/\(taskID.uuidString)?run=true",
            "floe://share?intake=\(taskID.uuidString)&intake=\(taskID.uuidString)",
            "floe://share?intake=\(taskID.uuidString)&run=true",
            "floe://user:password@new",
            "floe://new:123",
            "floe://new#run",
            "https://example.invalid/floe/new",
            "javascript:runTask()",
            "floe://task",
            "floe://task/not-a-uuid",
            "floe://task/../new",
            "floe://task/%2F\(taskID.uuidString)",
            "floe://task/\(taskID.uuidString)/other",
            "floe://share?intake",
            "floe://share?intake=",
            "floe://share?task=all",
            "floe://schedule/\(scheduleID.uuidString)?approve=true",
            "floe://task/\(taskID.uuidString)/\\n",
        ]
        for input in inputs {
            XCTAssertThrowsError(try C07AppEntryRoute.parse(input), input)
        }
    }

    func testOversizedLinksDoNotReachRouting() {
        let input = "floe://share?intake=" + String(repeating: "a", count: C07AppEntryRoute.maximumURLBytes)
        XCTAssertThrowsError(try C07AppEntryRoute.parse(input)) { error in
            XCTAssertEqual(error as? C07AppEntryRouteError, .tooLong)
        }
    }

    // MARK: - Share policy

    func testSharePolicyAcceptsBoundedSupportedItems() {
        let result = C07SharePolicy.validate([
            C07ShareItemDescriptor(kind: .text, mimeType: "text/plain", byteCount: 0, textBytes: 2048),
            C07ShareItemDescriptor(
                kind: .file,
                mimeType: "application/pdf",
                byteCount: 4_096,
                fileName: "Synthetic.pdf"
            ),
        ])
        guard case .success(let admission) = result else {
            return XCTFail("expected admission")
        }
        XCTAssertEqual(admission.items.count, 2)
        XCTAssertEqual(admission.totalKnownBytes, 4_096)
        XCTAssertEqual(admission.textBytes, 2_048)
        XCTAssertEqual(admission.items[0].mimeType, "text/plain")
    }

    func testSharePolicyRejectsCountTextItemAndTotalOverflow() {
        XCTAssertEqual(
            refusal(C07SharePolicy.validate(Array(repeating: descriptor(byteCount: 1), count: 6))),
            .itemLimit
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .text,
                    mimeType: "text/plain",
                    byteCount: 0,
                    textBytes: C07ShareLimits.standard.maxTextBytes + 1
                ),
            ])),
            .textTooLarge
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/pdf",
                    byteCount: C07ShareLimits.standard.maxItemBytes + 1,
                    fileName: "Synthetic.pdf"
                ),
            ])),
            .itemTooLarge
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                descriptor(byteCount: C07ShareLimits.standard.maxItemBytes),
                descriptor(byteCount: C07ShareLimits.standard.maxItemBytes),
                descriptor(byteCount: 1),
            ])),
            .totalTooLarge
        )
    }

    func testSharePolicyRejectsUnknownAndMislabeledPayloads() {
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/x-msdownload",
                    byteCount: 10,
                    fileName: "setup.exe"
                ),
            ])),
            .unsupportedType
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/octet-stream",
                    byteCount: 10,
                    fileName: "payload.unknown"
                ),
            ])),
            .unsupportedType
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/octet-stream",
                    byteCount: 10,
                    fileName: "payload.bin"
                ),
            ])),
            .unsupportedType
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/zip",
                    byteCount: 10,
                    fileName: "payload.bin"
                ),
            ])),
            .unsupportedType
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/pdf",
                    byteCount: -2,
                    fileName: "Synthetic.pdf"
                ),
            ])),
            .invalidDescriptor
        )
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/pdf",
                    byteCount: 10,
                    fileName: "bad\u{0}name.pdf"
                ),
            ])),
            .invalidDescriptor
        )
        XCTAssertEqual(refusal(C07SharePolicy.validate([])), .empty)
    }

    func testSharePolicyAdmitsExistingMediaCadSourceAsDataNotExecution() {
        let cases: [(mime: String, name: String)] = [
            ("image/heic", "photo.heic"),
            ("image/heif", "photo.heif"),
            ("image/avif", "photo.avif"),
            ("audio/mpeg", "voice.mp3"),
            ("audio/mp4", "voice.m4a"),
            ("video/mp4", "clip.mp4"),
            ("video/quicktime", "clip.mov"),
            ("application/dxf", "plan.dxf"),
            ("application/step", "part.step"),
            ("model/gltf-binary", "scene.glb"),
            ("text/x-python", "tool.py"),
            ("application/json", "data.json"),
            ("text/html", "page.html"),
            ("application/octet-stream", "notes.md"),
        ]
        for entry in cases {
            guard case .success(let admission) = C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: entry.mime,
                    byteCount: 1_024,
                    fileName: entry.name
                ),
            ]) else {
                XCTFail("expected admission for \(entry.mime)")
                continue
            }
            XCTAssertTrue(admission.taskAvailable, entry.mime)
            XCTAssertTrue(admission.notesAvailable, entry.mime)
            XCTAssertEqual(admission.packageKind, .none, entry.mime)
            XCTAssertEqual(admission.items.first?.mimeType, C07SharePolicy.normalizedMime(entry.mime))
        }
        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/vnd.android.package-archive",
                    byteCount: 10,
                    fileName: "install.apk"
                ),
            ])),
            .unsupportedType
        )
    }

    func testSharePolicyRoutesPackagesToSingleReviewOwner() {
        guard case .success(let note) = C07SharePolicy.validate([
            C07ShareItemDescriptor(
                kind: .file,
                mimeType: "application/zip",
                byteCount: 8_192,
                fileName: "Story.floenote"
            ),
        ]) else {
            return XCTFail("expected note package admission")
        }
        XCTAssertEqual(note.packageKind, .note)
        XCTAssertFalse(note.taskAvailable)
        XCTAssertFalse(note.notesAvailable)

        guard case .success(let backup) = C07SharePolicy.validate([
            C07ShareItemDescriptor(
                kind: .file,
                mimeType: "application/octet-stream",
                byteCount: C07ShareLimits.standard.maxItemBytes * 4,
                fileName: "Floe-backup.floebackup"
            ),
        ]) else {
            return XCTFail("expected backup package admission")
        }
        XCTAssertEqual(backup.packageKind, .backup)
        XCTAssertEqual(backup.totalKnownBytes, 0)

        guard case .success(let cad) = C07SharePolicy.validate([
            C07ShareItemDescriptor(
                kind: .file,
                mimeType: "application/octet-stream",
                byteCount: -1,
                fileName: "Model.floecad"
            ),
        ]) else {
            return XCTFail("expected cad package admission")
        }
        XCTAssertEqual(cad.packageKind, .cad)
        XCTAssertFalse(cad.taskAvailable)

        XCTAssertEqual(
            refusal(C07SharePolicy.validate([
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/zip",
                    byteCount: 10,
                    fileName: "Story.floenote"
                ),
                C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: "application/pdf",
                    byteCount: 10,
                    fileName: "Synthetic.pdf"
                ),
            ])),
            .packageMixed
        )
    }

    func testBridgeAdmissionExposesConsumerRouting() {
        let replyValue = reply(json(request("entry.validateShare", extra: [
            "items": [[
                "kind": "file",
                "mimeType": "image/heic",
                "byteCount": 12,
                "textBytes": 0,
                "fileName": "photo.heic",
            ]],
        ])))
        XCTAssertEqual(replyValue["ok"] as? Bool, true)
        let admission = replyValue["admission"] as? [String: Any]
        XCTAssertEqual(admission?["taskAvailable"] as? Bool, true)
        XCTAssertEqual(admission?["notesAvailable"] as? Bool, true)
        XCTAssertEqual(admission?["packageKind"] as? String, "none")
    }

    func testSharePolicyAcceptsHonestUnknownSizeAndKnownExtensions() {
        guard case .success(let admission) = C07SharePolicy.validate([
            C07ShareItemDescriptor(
                kind: .file,
                mimeType: "application/octet-stream",
                byteCount: -1,
                fileName: "Synthetic.pdf"
            ),
            C07ShareItemDescriptor(
                kind: .file,
                mimeType: "application/zip",
                byteCount: 20,
                fileName: "Synthetic.docx"
            ),
        ]) else {
            return XCTFail("expected admission")
        }
        XCTAssertEqual(admission.totalKnownBytes, 20)
    }

    // MARK: - Bridge

    func testHandshakeAdvertisesOnlyBoundedEntryPolicy() {
        let response = reply(json(request("handshake")))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["version"] as? Int, 24)
        XCTAssertEqual(response["schema"] as? String, "floe.entry/24")
        XCTAssertEqual(response["modelTools"] as? Bool, false)
        XCTAssertEqual(response["maxItems"] as? Int, 5)
        XCTAssertLessThanOrEqual(
            (try? JSONSerialization.data(withJSONObject: response))?.count ?? Int.max,
            BridgeV24.maximumResponseBytes
        )
    }

    func testParseLinkAndRefusals() {
        let ok = reply(json(request("entry.parseLink", extra: [
            "url": "floe://task/\(taskID.uuidString.lowercased())",
        ])))
        XCTAssertEqual(ok["ok"] as? Bool, true)
        let route = ok["route"] as? [String: Any]
        XCTAssertEqual(route?["kind"] as? String, "task")
        XCTAssertEqual(route?["id"] as? String, taskID.uuidString.lowercased())

        let refused = reply(json(request("entry.parseLink", extra: [
            "url": "floe://task/\(taskID.uuidString)?run=true",
        ])))
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["code"] as? String, "unexpectedParameters")
        XCTAssertNil(refused["route"])
    }

    func testValidateShareAndRefusal() {
        let valid = reply(json(request("entry.validateShare", extra: [
            "items": [[
                "kind": "file",
                "mimeType": "application/pdf",
                "byteCount": 12,
                "textBytes": 0,
                "fileName": "Synthetic.pdf",
            ]],
        ])))
        XCTAssertEqual(valid["ok"] as? Bool, true)
        let admission = valid["admission"] as? [String: Any]
        XCTAssertEqual(admission?["totalKnownBytes"] as? Int, 12)

        let refused = reply(json(request("entry.validateShare", extra: [
            "items": [[
                "kind": "file",
                "mimeType": "application/x-msdownload",
                "byteCount": 12,
                "textBytes": 0,
                "fileName": "setup.exe",
            ]],
        ])))
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["code"] as? String, "unsupportedType")
    }

    func testBridgeRejectsAuthorityBearingOrUnknownFields() {
        let withRun = reply(json(request("entry.parseLink", extra: [
            "url": "floe://new",
            "run": true,
            "permission": "all",
        ])))
        XCTAssertEqual(withRun["ok"] as? Bool, false)
        XCTAssertEqual(withRun["code"] as? String, "unexpectedKeys")

        var wrongVersion = request("handshake")
        wrongVersion["version"] = 23
        XCTAssertEqual(
            reply(json(wrongVersion))["code"] as? String,
            "unsupportedVersion"
        )

        var wrongSchema = request("handshake")
        wrongSchema["schema"] = "floe.entry/23"
        XCTAssertEqual(
            reply(json(wrongSchema))["code"] as? String,
            "invalidSchema"
        )

        XCTAssertEqual(
            reply(json(request("entry.execute")))["code"] as? String,
            "unsupportedOperation"
        )
        XCTAssertEqual(
            reply(json(request("entry.validateShare", extra: [
                "items": [["kind": "text", "mimeType": "", "byteCount": 0, "textBytes": 1, "extra": 1]],
            ])))["code"] as? String,
            "invalidDescriptor"
        )
    }

    func testBridgeRequestCeilingFailsClosed() {
        let oversized = Data(repeating: 0x20, count: BridgeV24.maximumRequestBytes + 1)
        XCTAssertEqual(
            reply(oversized)["code"] as? String,
            "requestTooLarge"
        )
        let response = reply(json(request("handshake")))
        let encoded = try? JSONSerialization.data(
            withJSONObject: response,
            options: [.sortedKeys]
        )
        XCTAssertLessThanOrEqual(encoded?.count ?? Int.max, BridgeV24.maximumResponseBytes)
    }

    // MARK: - Helpers

    private func descriptor(byteCount: Int64) -> C07ShareItemDescriptor {
        C07ShareItemDescriptor(
            kind: .file,
            mimeType: "application/pdf",
            byteCount: byteCount,
            fileName: "Synthetic.pdf"
        )
    }

    private func refusal(
        _ result: Result<C07ShareAdmission, C07ShareRefusal>
    ) -> C07ShareRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    private func request(
        _ operation: String,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var value: [String: Any] = [
            "version": BridgeV24.version,
            "schema": BridgeV24.schema,
            "operation": operation,
            "requestID": "test-request",
        ]
        for (key, element) in extra { value[key] = element }
        return value
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
    }

    private func reply(_ data: Data) -> [String: Any] {
        C07AppEntryBridge.handle(
            requestData: data,
            fallbackRequestID: "test-request"
        )
    }
}
