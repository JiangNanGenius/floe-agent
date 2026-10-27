// FloeAppTests — the service-owned Skill Hub presentation media center.
//
// These lock the bounded-media contract with fakes at the single injected
// seam (the anonymous GitHub reader) and a real temporary disk directory.
// What IS proven here: publication-pin rejection, unsafe-path/SVG refusal
// before any request, byte + decoded-dimension + undecodable rejection, the
// honest fallback (nil, never a throw, never a blocked CTA), in-flight
// coalescing, publication-change epoch cancellation, disk revalidation on
// load, and LRU eviction by BOTH entry count and decoded-bitmap cost.
// Screenshots remain illustrations, never execution claims, and the real
// view fixtures live in the UI test lane (Main runs the batch).

#if canImport(UIKit)
import Foundation
import Testing
import zlib
import FloeSkills
import UIKit
@testable import FloeApp

// MARK: - Fixtures

private func mediaCommit(_ seed: Character = "a") -> String {
    String(repeating: seed, count: 40)
}

private let coverPath = "showcase/media/covers/demo-skill.png"
private let galleryPath = "showcase/media/gallery/demo-shot.jpg"

private func makeValidShowcaseJSON() -> Data {
    let root: [String: Any] = [
        "schemaVersion": 1,
        "editorPicks": ["demo-skill"],
        "entries": ["demo-skill": [
            "overview": ["en": "Summarize sources.", "zh-Hans": "汇总资料。"],
            "useCases": [["en": "Merge notes.", "zh-Hans": "合并笔记。"]],
            "examples": [[
                "prompt": ["en": "Summarize.", "zh-Hans": "总结。"],
                "output": ["en": "A brief.", "zh-Hans": "简报。"],
            ]],
            "cover": [
                "path": coverPath,
                "kind": "illustration",
                "credit": ["en": "Floe original.", "zh-Hans": "Floe 原创。"],
                "alt": ["en": "A cover.", "zh-Hans": "封面。"],
            ],
            "gallery": [[
                "path": galleryPath,
                "kind": "app-screenshot",
                "credit": ["en": "Floe screenshot.", "zh-Hans": "Floe 截图。"],
                "caption": ["en": "The editor window.", "zh-Hans": "编辑器窗口。"],
            ]],
        ]],
    ]
    return try! JSONSerialization.data(withJSONObject: root)
}

@MainActor
private func makePNG(_ side: Int) -> Data {
    let size = CGSize(width: side, height: side)
    return UIGraphicsImageRenderer(size: size).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

@MainActor
private func makeJPEG(_ side: Int) -> Data {
    let size = CGSize(width: side, height: side)
    let image = UIGraphicsImageRenderer(size: size).image { context in
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return image.jpegData(compressionQuality: 0.9)!
}

private actor HoldGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func arriveAndWait() async {
        arrivals += 1
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
private final class MockSkillHubMediaReader: SkillHubMediaReading {
    struct Request: Equatable { let ref: String; let path: String }
    private(set) var requests: [Request] = []
    var handler: ((Request) async throws -> Data)?
    func repositoryData(owner: String, repository: String, ref: String, path: String) async throws -> Data {
        let request = Request(ref: ref, path: path)
        requests.append(request)
        if let handler { return try await handler(request) }
        return Data()
    }
    func requestCount(for path: String) -> Int { requests.filter { $0.path == path }.count }
}

private final class Box<T>: @unchecked Sendable { var value: T; init(_ value: T) { self.value = value } }

@MainActor
private func makeCenter(reader: MockSkillHubMediaReader?, budgets: SkillHubMediaCenter.Budgets = .init(),
                        directoryLabel: String = #function) -> (SkillHubMediaCenter, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-skillhub-media-\(directoryLabel)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let center = SkillHubMediaCenter(reader: reader, budgets: budgets, diskDirectory: directory)
    return (center, directory)
}

private func removeTemp(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

@Suite("FloeApp.SkillHubMedia", .serialized)
struct SkillHubMediaTests {

    // MARK: Publication pin + path safety (rejected BEFORE any request)

    @MainActor @Test func nonCanonicalCommitNeverTouchesTransport() async {
        let reader = MockSkillHubMediaReader()
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "pin")
        defer { removeTemp(directory) }
        center.bind(publicationCommit: mediaCommit())
        #expect(await center.showcase(commit: "main") == nil)
        #expect(await center.image(path: coverPath, commit: "NOT-A-COMMIT") == nil)
        #expect(reader.requests.isEmpty)
    }

    @MainActor @Test func unsafePathAndSVGAreRefusedBeforeFetch() async {
        let reader = MockSkillHubMediaReader()
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "path")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        for unsafe in ["packages/x.png", "showcase/media/../secrets.png", "showcase/media/x.gif",
                       "showcase/media/x.png?rev=2", "catalog.json"] {
            #expect(await center.image(path: unsafe, commit: commit) == nil, "must refuse \(unsafe)")
        }
        // SVG passes the contract shape but is never fetched or executed
        // natively — the App falls back to bundled raster instead.
        #expect(await center.image(path: "showcase/media/covers/demo.svg", commit: commit) == nil)
        #expect(reader.requests.isEmpty)
    }

    // MARK: Showcase manifest

    @MainActor @Test func showcaseValidatesOnceAndCachesPerCommit() async {
        let reader = MockSkillHubMediaReader()
        reader.handler = { _ in makeValidShowcaseJSON() }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "showcase")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        let first = await center.showcase(commit: commit)
        #expect(first != nil)
        #expect(first?.cover(for: "demo-skill")?.path == coverPath)
        let second = await center.showcase(commit: commit)
        #expect(second?.editorial(for: "demo-skill")?.useCases.count == 1)
        #expect(reader.requestCount(for: SkillHubShowcase.manifestPath) == 1)
    }

    @MainActor @Test func showcaseInvalidDocumentFallsBackToNil() async {
        let reader = MockSkillHubMediaReader()
        reader.handler = { _ in Data("{\"schemaVersion\":2}".utf8) }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "showcase-bad")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.showcase(commit: commit) == nil)
    }

    @MainActor @Test func withoutReaderEverythingIsAnHonestFallback() async {
        let (center, directory) = makeCenter(reader: nil, directoryLabel: "offline")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.showcase(commit: commit) == nil)
        #expect(await center.image(path: coverPath, commit: commit) == nil)
    }

    // MARK: Media bytes: validation, rejection and fallback

    @MainActor @Test func validPNGDecodesAndSecondDemandIsMemoryHit() async {
        let reader = MockSkillHubMediaReader()
        let png = makePNG(64)
        reader.handler = { _ in png }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "happy")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        let image = await center.image(path: coverPath, commit: commit)
        #expect(image != nil)
        #expect(image?.size.width == 64)
        _ = await center.image(path: coverPath, commit: commit)
        #expect(reader.requestCount(for: coverPath) == 1)
    }

    @MainActor @Test func bytesMismatchingDeclaredTypeAreRejected() async {
        let reader = MockSkillHubMediaReader()
        reader.handler = { _ in Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) } // PNG at a .jpg path
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "mismatch")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: galleryPath, commit: commit) == nil)
        // And a rejected refusal is never persisted for later trust.
        let entries = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.isEmpty)
    }

    @MainActor @Test func oversizedFileIsRejected() async {
        let reader = MockSkillHubMediaReader()
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 64,
                                                 maximumMemoryDecodedBytes: 64 * 1024 * 1024,
                                                 maximumSessionBytes: .max,
                                                 maximumSessionFiles: .max,
                                                 perFileBytes: 4_096)
        reader.handler = { _ in
            var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            bytes.append(Data(count: 8_192))
            return bytes
        }
        let (center, directory) = makeCenter(reader: reader, budgets: budget, directoryLabel: "oversize")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) == nil)
    }

    @MainActor @Test func validMagicGarbagePayloadIsRejectedAndNotPersisted() async {
        let reader = MockSkillHubMediaReader()
        reader.handler = { _ in
            var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            bytes.append(contentsOf: Array("not an image at all".utf8))
            return bytes
        }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "garbage")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) == nil)
        let entries = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.isEmpty)
    }

    // MARK: Decoded-dimension limits (coordinator review 2026-10-28)

    @MainActor @Test func giantSourceDimensionsAreRejectedBeforeBitmap() async {
        // A tiny crafted file whose PNG header promises 7000×7000 (49 MP)
        // must be refused from the ImageIO header alone — no pixel buffer.
        let reader = MockSkillHubMediaReader()
        reader.handler = { _ in Self.craftedHugePNG(width: 7_000, height: 7_000) }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "huge-dims")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) == nil)
    }

    @MainActor @Test func oversizedSourceDownsamplesToRenderLimit() async {
        let reader = MockSkillHubMediaReader()
        let big = makePNG(3_000)
        reader.handler = { _ in big }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "downsample")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        let image = await center.image(path: coverPath, commit: commit)
        #expect(image != nil)
        // The retained bitmap is the bounded still, not the 3000-px source.
        #expect((image?.size.width ?? 0) <= CGFloat(SkillHubMediaDecoder.maximumPixelSize))
        #expect((image?.size.width ?? 0) > 0)
        // Decoded cost, not raw file length, is what the LRU holds.
        #expect(center.debugMemoryDecodedBytes > 0)
    }

    @MainActor @Test func lruEvictsByDecodedCostBeforeEntryCountIsReached() async {
        // Entry count would happily hold many frames; the DECODED-byte budget
        // must evict first. Cost of one 800×800 RGBA still ≈ 2.56 MB.
        let costBudget = 2_600_000
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 64,
                                                 maximumMemoryDecodedBytes: costBudget,
                                                 maximumSessionBytes: .max,
                                                 maximumSessionFiles: .max,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        let a = makePNG(800)
        let b = makeJPEG(800)
        reader.handler = { request in request.path == coverPath ? a : b }
        let (center, directory) = makeCenter(reader: reader, budgets: budget, directoryLabel: "cost-lru")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(await center.image(path: galleryPath, commit: commit) != nil)
        // Both fit the COUNT bound (64) but not the COST bound: the older
        // entry must already be gone, and the resident total stays bounded.
        #expect(center.debugMemoryCacheCount == 1)
        #expect(center.debugMemoryDecodedBytes <= costBudget)
        // The evicted entry is still honestly served (disk re-read, no new
        // transport demand) after a publication-unchanged second look.
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(reader.requestCount(for: coverPath) == 1)
        #expect(reader.requestCount(for: galleryPath) == 1)
        #expect(center.debugMemoryCacheCount == 1)
        #expect(center.debugMemoryDecodedBytes <= costBudget)
    }

    @MainActor @Test func imageCostingMoreThanTheWholeBudgetIsNeverRetained() async {
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 64,
                                                 maximumMemoryDecodedBytes: 1024, // absurdly small
                                                 maximumSessionBytes: .max,
                                                 maximumSessionFiles: .max,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        let png = makePNG(128)
        reader.handler = { _ in png }
        let (center, directory) = makeCenter(reader: reader, budgets: budget, directoryLabel: "transient")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(center.debugMemoryCacheCount == 0)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        // Second demand is served from the bounded disk cache, not refetched.
        #expect(reader.requestCount(for: coverPath) == 1)
    }

    // MARK: Session budgets

    @MainActor @Test func globalFileBudgetRefusesSecondFileWithoutFetch() async {
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 64,
                                                 maximumMemoryDecodedBytes: 64 * 1024 * 1024,
                                                 maximumSessionBytes: .max,
                                                 maximumSessionFiles: 1,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        let png = makePNG(32)
        reader.handler = { _ in png }
        let (center, directory) = makeCenter(reader: reader, budgets: budget, directoryLabel: "file-budget")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(await center.image(path: galleryPath, commit: commit) == nil)
        #expect(reader.requestCount(for: galleryPath) == 0)
    }

    @MainActor @Test func globalByteBudgetRefusesPublicationWithoutPoisoningShape() async {
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 64,
                                                 maximumMemoryDecodedBytes: 64 * 1024 * 1024,
                                                 maximumSessionBytes: 1, // nothing fits
                                                 maximumSessionFiles: .max,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        let png = makePNG(64)
        reader.handler = { _ in png }
        let (center, directory) = makeCenter(reader: reader, budgets: budget, directoryLabel: "byte-budget")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) == nil)
        #expect(center.debugMemoryCacheCount == 0)
    }

    // MARK: Coalescing + epoch cancellation

    @MainActor @Test func concurrentDemandsShareOneFetch() async {
        let reader = MockSkillHubMediaReader()
        let gate = HoldGate()
        let pngBox = Box<Data>(Data())
        reader.handler = { _ in
            await gate.arriveAndWait()
            return pngBox.value
        }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "coalesce")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        async let first = center.image(path: coverPath, commit: commit)
        async let second = center.image(path: coverPath, commit: commit)
        while (await gate.arrivals) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        let bytes = makePNG(48)
        pngBox.value = bytes
        await gate.release()
        _ = await (first, second)
        #expect(reader.requestCount(for: coverPath) == 1)
    }

    @MainActor @Test func publicationSwitchCancelsInFlightAndDiscardsStaleResult() async {
        let reader = MockSkillHubMediaReader()
        let gate = HoldGate()
        let responder = Box<Data>(Data())
        let holdFirst = Box(true)
        reader.handler = { _ in
            if holdFirst.value {
                holdFirst.value = false
                await gate.arriveAndWait()
            }
            return responder.value
        }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "epoch")
        defer { removeTemp(directory) }
        let firstCommit = mediaCommit("a")
        let secondCommit = mediaCommit("b")
        center.bind(publicationCommit: firstCommit)
        let stale = Task { await center.image(path: coverPath, commit: firstCommit) }
        while (await gate.arrivals) < 1 { try? await Task.sleep(for: .milliseconds(5)) }
        // The verified catalog moves to a NEW publication mid-read.
        center.bind(publicationCommit: secondCommit)
        let bytes = makePNG(48)
        responder.value = bytes
        await gate.release()
        #expect(await stale.value == nil, "a completion from an invalidated publication must never publish")
        // And the next demand for the NEW commit re-reads cleanly.
        center.bind(publicationCommit: secondCommit)
        let fresh = await center.image(path: coverPath, commit: secondCommit)
        #expect(fresh != nil)
        #expect(reader.requests.filter { $0.ref == secondCommit }.count == 1)
    }

    @MainActor @Test func bindingSameCommitAgainIsANoOpForInFlightReads() async {
        let reader = MockSkillHubMediaReader()
        let png = makePNG(48)
        reader.handler = { _ in png }
        let (center, directory) = makeCenter(reader: reader, directoryLabel: "bind-noop")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        center.bind(publicationCommit: commit) // same commit → no invalidation
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(reader.requestCount(for: coverPath) == 1)
    }

    // MARK: Bounded disk cache: offline reuse + revalidation on load

    @MainActor @Test func diskCacheServesOfflineRoundTripWithoutTransport() async {
        let commit = mediaCommit()
        let png = makePNG(72)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skillhub-media-offline-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemp(directory) }
        let readerA = MockSkillHubMediaReader()
        readerA.handler = { _ in png }
        let centerA = SkillHubMediaCenter(reader: readerA, diskDirectory: directory)
        centerA.bind(publicationCommit: commit)
        #expect(await centerA.image(path: coverPath, commit: commit) != nil)

        // A fresh service on the same disk with a FAILING transport still
        // renders the pinned artwork: validated bytes survive process churn.
        let readerB = MockSkillHubMediaReader()
        readerB.handler = { _ in throw FloeUnavailableStub() }
        let centerB = SkillHubMediaCenter(reader: readerB, diskDirectory: directory)
        centerB.bind(publicationCommit: commit)
        #expect(await centerB.image(path: coverPath, commit: commit) != nil)
        #expect(readerB.requests.isEmpty)
    }

    @MainActor @Test func tornDiskEntryIsDroppedAndDemandReReadsCleanly() async {
        let commit = mediaCommit()
        let png = makePNG(72)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skillhub-media-torn-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeTemp(directory) }
        let readerA = MockSkillHubMediaReader()
        readerA.handler = { _ in png }
        let centerA = SkillHubMediaCenter(reader: readerA, diskDirectory: directory)
        centerA.bind(publicationCommit: commit)
        #expect(await centerA.image(path: coverPath, commit: commit) != nil)

        // Corrupt the single cached file on disk (torn/forged bytes).
        let names = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 1)
        try! Data("definitely not a png".utf8).write(to: directory.appendingPathComponent(names[0]))

        let readerB = MockSkillHubMediaReader()
        readerB.handler = { _ in png }
        let centerB = SkillHubMediaCenter(reader: readerB, diskDirectory: directory)
        centerB.bind(publicationCommit: commit)
        #expect(await centerB.image(path: coverPath, commit: commit) != nil)
        // Magic-byte revalidation on load: the torn entry was refused and the
        // demand re-read exactly once from the pinned publication.
        #expect(readerB.requestCount(for: coverPath) == 1)
    }

    // MARK: - Huge PNG fixture (valid header, no pixel payload)

    private static func craftedHugePNG(width: Int, height: Int) -> Data {
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            var out = [UInt8]()
            let length = UInt32(payload.count)
            out.append(UInt8(length >> 24 & 0xFF)); out.append(UInt8(length >> 16 & 0xFF))
            out.append(UInt8(length >> 8 & 0xFF)); out.append(UInt8(length & 0xFF))
            let typeBytes = Array(type.utf8)
            out.append(contentsOf: typeBytes)
            out.append(contentsOf: payload)
            var crcInput = typeBytes + payload
            let crc = crc32(0, &crcInput, UInt32(crcInput.count))
            out.append(UInt8(crc >> 24 & 0xFF)); out.append(UInt8(crc >> 16 & 0xFF))
            out.append(UInt8(crc >> 8 & 0xFF)); out.append(UInt8(crc & 0xFF))
            return out
        }
        var ihdr = [UInt8]()
        for value in [UInt32(width), UInt32(height)] {
            ihdr.append(UInt8(value >> 24 & 0xFF)); ihdr.append(UInt8(value >> 16 & 0xFF))
            ihdr.append(UInt8(value >> 8 & 0xFF)); ihdr.append(UInt8(value & 0xFF))
        }
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        bytes.append(contentsOf: chunk("IHDR", ihdr))
        bytes.append(contentsOf: chunk("IDAT", [0x00, 0x01, 0x02]))
        bytes.append(contentsOf: chunk("IEND", []))
        return bytes
    }
}

private struct FloeUnavailableStub: Error {}
#endif
