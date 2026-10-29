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
import ImageIO
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
private let thirdPath = "showcase/media/gallery/third-shot.png"

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

/// Deterministic bitmap fixtures: exactly one encoded pixel per requested
/// point. `UIGraphicsImageRendererFormat()` defaults to `scale = 0`, which
/// resolves to the HOST display scale (2 on the canonical iPad mini), so
/// `makePNG(64)` would otherwise encode a 128-px PNG and the decoded-size /
/// decoded-cost expectations below would measure the fixture rather than the
/// center's real contract.
@MainActor
private func bitmapFixtureFormat() -> UIGraphicsImageRendererFormat {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return format
}

@MainActor
private func makePNG(_ side: Int) -> Data {
    let size = CGSize(width: side, height: side)
    return UIGraphicsImageRenderer(size: size, format: bitmapFixtureFormat()).pngData { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

@MainActor
private func makeJPEG(_ side: Int) -> Data {
    let size = CGSize(width: side, height: side)
    let image = UIGraphicsImageRenderer(size: size, format: bitmapFixtureFormat()).image { context in
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return image.jpegData(compressionQuality: 0.9)!
}

/// Encoded pixel dimensions, independent of any UIImage point scale.
private func fixturePixelSize(_ data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
        return nil
    }
    return CGSize(width: width, height: height)
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

/// Simulates the disk entry being lost/replaced. The service must re-read the
/// pinned publication instead of silently trusting a different payload.
private func clearDiskCache(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

@Suite("FloeApp.SkillHubMedia", .serialized)
struct SkillHubMediaTests {

    // MARK: Deterministic bitmap fixtures

    @MainActor @Test func bitmapFixturesPinPixelDimensions() {
        // Locks the fixture contract the decoded-size and decoded-cost
        // expectations below measure: one encoded pixel per requested point
        // even on a 2x host display, so a fixture regression cannot be
        // mistaken for a center regression.
        #expect(fixturePixelSize(makePNG(64)) == CGSize(width: 64, height: 64))
        #expect(fixturePixelSize(makeJPEG(800)) == CGSize(width: 800, height: 800))
        #expect(fixturePixelSize(makePNG(3_000)) == CGSize(width: 3_000, height: 3_000))
    }

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
        // The fixture is 64 PIXELS and the decode contract returns the still
        // at scale 1, so the presentation size is the decoded pixel size
        // (views resize it); this stays independent of host display scale.
        #expect(image?.cgImage?.width == 64)
        #expect(image?.cgImage?.height == 64)
        #expect(image?.scale == 1)
        #expect(center.debugMemoryCacheCount == 1)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == png.count)
        _ = await center.image(path: coverPath, commit: commit)
        #expect(reader.requestCount(for: coverPath) == 1)
        // A memory hit is the same admitted identity: no new session charge.
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == png.count)
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
        // Nor does a refused payload ever charge the session identity budget.
        #expect(center.debugSessionFileCount == 0)
        #expect(center.debugSessionBytes == 0)
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
        #expect(center.debugSessionFileCount == 0)
        #expect(center.debugSessionBytes == 0)
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
        #expect(center.debugSessionFileCount == 0)
        #expect(center.debugSessionBytes == 0)
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
        #expect(center.debugSessionFileCount == 0)
        #expect(center.debugSessionBytes == 0)
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
        // must evict first. The 1-px-per-point fixtures make one 800×800
        // RGBA still cost 800 × 4 × 800 = 2.56 MB on any host display scale.
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
        let singleStillCost = center.debugMemoryDecodedBytes
        #expect(singleStillCost > 0)
        #expect(singleStillCost <= costBudget, "one 800×800 still must fit alone")
        #expect(singleStillCost * 2 > costBudget, "two 800×800 stills must not both fit")
        #expect(await center.image(path: galleryPath, commit: commit) != nil)
        // Both fit the COUNT bound (64) but not the COST bound: the older
        // entry must already be gone, and the resident total stays bounded.
        #expect(center.debugMemoryCacheCount == 1)
        #expect(center.debugMemoryDecodedBytes <= costBudget)
        // Exactly one still remains resident (a single still is more than
        // half the budget, so this cannot be a count-bound artifact).
        #expect(center.debugMemoryDecodedBytes > costBudget / 2)
        // The evicted entry is still honestly served (disk re-read, no new
        // transport demand) after a publication-unchanged second look.
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(reader.requestCount(for: coverPath) == 1)
        #expect(reader.requestCount(for: galleryPath) == 1)
        #expect(center.debugMemoryCacheCount == 1)
        #expect(center.debugMemoryDecodedBytes <= costBudget)
        #expect(center.debugMemoryDecodedBytes > costBudget / 2)
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
        // A demand refused by the encoded-byte cap never becomes an identity.
        #expect(center.debugSessionFileCount == 0)
        #expect(center.debugSessionBytes == 0)
    }

    // MARK: Session identity accounting (distinct artwork, not demands)

    @MainActor @Test func repeatedDiskRereadsOfAdmittedArtworkNeverExhaustSessionBudget() async {
        // The reported product bug: a small gallery scrolls far past the
        // 256-file / 32 MB session budget because every memory eviction is a
        // disk re-decode that used to charge sessionFiles/sessionBytes again.
        // Here the budget is exactly the two distinct stills and nothing is
        // retained in the decoded LRU, so every one of the 600 later demands
        // is a validated disk re-read of an already admitted identity.
        let png = makePNG(64)
        let jpeg = makeJPEG(64)
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 1,
                                                 maximumMemoryDecodedBytes: 1, // never retain
                                                 maximumSessionBytes: png.count + jpeg.count,
                                                 maximumSessionFiles: 2,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        reader.handler = { request in
            switch request.path {
            case coverPath: return png
            case galleryPath: return jpeg
            default: return png
            }
        }
        let (center, directory) = makeCenter(reader: reader, budgets: budget, directoryLabel: "reread-budget")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(await center.image(path: galleryPath, commit: commit) != nil)
        #expect(center.debugSessionFileCount == 2)
        #expect(center.debugSessionBytes == png.count + jpeg.count)
        #expect(center.debugMemoryCacheCount == 0)
        var served = 0
        for _ in 0..<300 {
            if await center.image(path: coverPath, commit: commit) != nil { served += 1 }
            if await center.image(path: galleryPath, commit: commit) != nil { served += 1 }
        }
        #expect(served == 600, "all 600 disk re-reads of the same two identities still return images")
        // Every later demand was a disk re-read: no extra network, and no
        // extra identity charge. Before the fix the second cycle already
        // refused these stills once the tiny session cap was reached.
        #expect(reader.requestCount(for: coverPath) == 1)
        #expect(reader.requestCount(for: galleryPath) == 1)
        #expect(center.debugSessionFileCount == 2)
        #expect(center.debugSessionBytes == png.count + jpeg.count)
        // The budget still bounds DISTINCT artwork: a new identity is
        // refused up front, without touching the transport.
        #expect(await center.image(path: thirdPath, commit: commit) == nil)
        #expect(reader.requestCount(for: thirdPath) == 0)
        #expect(center.debugSessionFileCount == 2)
    }

    @MainActor @Test func concurrentDistinctAdmissionsCannotOvershootUniqueFileBudget() async {
        // One free unique-file slot. Both contenders pass the cheap preflight
        // and are suspended in transport together; only the post-await
        // admission may take the slot, and the loser must charge nothing.
        let seeded = makePNG(32)
        let contenderA = makePNG(40)
        let contenderB = makePNG(48)
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 1,
                                                 maximumMemoryDecodedBytes: 1,
                                                 maximumSessionBytes: seeded.count + contenderA.count + contenderB.count,
                                                 maximumSessionFiles: 2,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        let gate = HoldGate()
        let armed = Box(false)
        reader.handler = { request in
            if armed.value { await gate.arriveAndWait() }
            switch request.path {
            case coverPath: return seeded
            case galleryPath: return contenderA
            default: return contenderB
            }
        }
        let (center, directory) = makeCenter(reader: reader, budgets: budget,
                                             directoryLabel: "concurrent-files")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(center.debugSessionFileCount == 1)
        armed.value = true
        async let first = center.image(path: galleryPath, commit: commit)
        async let second = center.image(path: thirdPath, commit: commit)
        var spins = 0
        while (await gate.arrivals) < 2 && spins < 600 {
            try? await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        #expect(await gate.arrivals >= 2)
        await gate.release()
        let results = await (first, second)
        #expect([results.0, results.1].compactMap { $0 }.count == 1,
                "only one new identity may take the last unique-file slot")
        #expect(center.debugSessionFileCount == 2)
        let admittedBytes = results.0 != nil ? contenderA.count : contenderB.count
        #expect(center.debugSessionBytes == seeded.count + admittedBytes)
        // The refused identity stays refused for this session.
        let refusedPath = results.0 != nil ? thirdPath : galleryPath
        #expect(await center.image(path: refusedPath, commit: commit) == nil)
        #expect(center.debugSessionFileCount == 2)
    }

    @MainActor @Test func concurrentDistinctAdmissionsCannotOvershootEncodedByteBudget() async {
        // One payload fits, two do not. Both new identities pass the cheap
        // preflight while the session is empty; the post-await admission must
        // re-check the encoded-byte cap and admit exactly one.
        let contenderA = makePNG(40)
        let contenderB = makePNG(48)
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 1,
                                                 maximumMemoryDecodedBytes: 1,
                                                 maximumSessionBytes: max(contenderA.count, contenderB.count),
                                                 maximumSessionFiles: 8,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        #expect(contenderA.count + contenderB.count > budget.maximumSessionBytes)
        let reader = MockSkillHubMediaReader()
        let gate = HoldGate()
        let armed = Box(true)
        reader.handler = { request in
            if armed.value { await gate.arriveAndWait() }
            return request.path == galleryPath ? contenderA : contenderB
        }
        let (center, directory) = makeCenter(reader: reader, budgets: budget,
                                             directoryLabel: "concurrent-bytes")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        async let first = center.image(path: galleryPath, commit: commit)
        async let second = center.image(path: thirdPath, commit: commit)
        var spins = 0
        while (await gate.arrivals) < 2 && spins < 600 {
            try? await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        #expect(await gate.arrivals >= 2)
        await gate.release()
        let results = await (first, second)
        #expect([results.0, results.1].compactMap { $0 }.count == 1,
                "only one new identity may fit the encoded-byte cap")
        #expect(center.debugSessionFileCount == 1)
        let admittedBytes = results.0 != nil ? contenderA.count : contenderB.count
        #expect(center.debugSessionBytes == admittedBytes)
        // The loser charged nothing and remains refused.
        let refusedPath = results.0 != nil ? thirdPath : galleryPath
        #expect(await center.image(path: refusedPath, commit: commit) == nil)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == admittedBytes)
    }

    @MainActor @Test func sameKeyLargerPayloadMustFitGrowthOrIsRefusedWithoutCharging() async {
        let small = makePNG(32)
        let large = makePNG(64)
        #expect(large.count > small.count)
        // Room for the admitted small payload, but not for the growth to the
        // larger payload under the same key.
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 1,
                                                 maximumMemoryDecodedBytes: 1,
                                                 maximumSessionBytes: large.count - 1,
                                                 maximumSessionFiles: 4,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        #expect(budget.maximumSessionBytes >= small.count)
        let reader = MockSkillHubMediaReader()
        let payload = Box(small)
        reader.handler = { _ in payload.value }
        let (center, directory) = makeCenter(reader: reader, budgets: budget,
                                             directoryLabel: "growth-reject")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == small.count)
        // A later LARGER payload under the same key: its growth does not fit,
        // so the demand is refused and the identity stays charged at the
        // already admitted size.
        clearDiskCache(directory)
        payload.value = large
        #expect(await center.image(path: coverPath, commit: commit) == nil)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == small.count)
        // The admitted identity itself is still readable and never re-charged.
        clearDiskCache(directory)
        payload.value = small
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(reader.requestCount(for: coverPath) == 3)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == small.count)
    }

    @MainActor
    @Test func sameKeyLargerPayloadChargesOnlyGrowthAndDifferentPathCannotRideFree() async {
        let small = makePNG(32)
        let large = makePNG(64)
        #expect(large.count > small.count)
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 1,
                                                 maximumMemoryDecodedBytes: 1,
                                                 maximumSessionBytes: large.count,
                                                 maximumSessionFiles: 4,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        let payload = Box(small)
        reader.handler = { _ in payload.value }
        let (center, directory) = makeCenter(reader: reader, budgets: budget,
                                             directoryLabel: "growth-accept")
        defer { removeTemp(directory) }
        let commit = mediaCommit()
        center.bind(publicationCommit: commit)
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(center.debugSessionBytes == small.count)
        clearDiskCache(directory)
        payload.value = large
        #expect(await center.image(path: coverPath, commit: commit) != nil)
        #expect(center.debugSessionFileCount == 1, "a larger payload is the same identity")
        #expect(center.debugSessionBytes == large.count, "only the growth is charged")
        // A DIFFERENT path cannot ride free past the fully charged cap.
        #expect(await center.image(path: galleryPath, commit: commit) == nil)
        #expect(reader.requestCount(for: galleryPath) == 0)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == large.count)
    }

    @MainActor @Test func bindingANewPublicationResetsSessionIdentityBudget() async {
        let png = makePNG(32)
        let budget = SkillHubMediaCenter.Budgets(maximumMemoryEntries: 4,
                                                 maximumMemoryDecodedBytes: 1,
                                                 maximumSessionBytes: png.count,
                                                 maximumSessionFiles: 1,
                                                 perFileBytes: SkillHubShowcase.maximumMediaBytes)
        let reader = MockSkillHubMediaReader()
        reader.handler = { _ in png }
        let (center, directory) = makeCenter(reader: reader, budgets: budget,
                                             directoryLabel: "bind-reset")
        defer { removeTemp(directory) }
        let firstCommit = mediaCommit("a")
        let secondCommit = mediaCommit("b")
        center.bind(publicationCommit: firstCommit)
        #expect(await center.image(path: coverPath, commit: firstCommit) != nil)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == png.count)
        #expect(await center.image(path: galleryPath, commit: firstCommit) == nil)
        // A different immutable publication is a new session: both identity
        // counters reset, so the same path may be admitted again at B.
        center.bind(publicationCommit: secondCommit)
        #expect(center.debugSessionFileCount == 0)
        #expect(center.debugSessionBytes == 0)
        #expect(await center.image(path: coverPath, commit: secondCommit) != nil)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == png.count)
        // Re-binding the SAME commit is still a no-op, not a free reset.
        center.bind(publicationCommit: secondCommit)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == png.count)
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
        // The invalidated work charged nothing.
        #expect(center.debugSessionFileCount == 0)
        #expect(center.debugSessionBytes == 0)
        // And the next demand for the NEW commit re-reads cleanly.
        center.bind(publicationCommit: secondCommit)
        let fresh = await center.image(path: coverPath, commit: secondCommit)
        #expect(fresh != nil)
        #expect(reader.requests.filter { $0.ref == secondCommit }.count == 1)
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == bytes.count)
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
        // Re-binding the SAME publication keeps the admitted identity count.
        #expect(center.debugSessionFileCount == 1)
        #expect(center.debugSessionBytes == png.count)
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
