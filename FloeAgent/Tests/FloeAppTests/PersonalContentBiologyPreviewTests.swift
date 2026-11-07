// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreGraphics
import ImageIO
import Testing
import FloeBiologyCore
@testable import FloeApp

@Suite("Saved Biology original previews", .serialized)
@MainActor struct PersonalContentBiologyPreviewTests {
    private struct Fixture {
        let root: URL; let storeRoot: URL; let wrapper: URL; let id: UUID; let store: BiologyProjectStore; let asset: BiologyAsset
    }
    private func fixture(_ asset: BiologyAsset) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biology-preview-" + UUID().uuidString).standardizedFileURL.resolvingSymlinksInPath(), id = UUID()
        let library = root.appendingPathComponent("PersonalContent"), wrapper = library.appendingPathComponent("Owned.floeproject")
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        let storeRoot = BiologyAppComposition.permanentRoot(forLibraryRoot: library).appendingPathComponent("Projects")
        let store = try BiologyProjectStore(root: storeRoot)
        _ = try await store.createBound(id: id, title: "This title is not the preview")
        _ = try await store.update(id, expectedRevision: 1) { project in project.assets = [asset]; project.activeAssetID = asset.id }
        try BiologyOriginalBinding(projectID: id).write(to: wrapper)
        return .init(root: root, storeRoot: storeRoot, wrapper: wrapper, id: id, store: store, asset: asset)
    }
    private func request(_ f: Fixture, service: PersonalContentPreviewService) async throws -> PersonalContentPreviewRequest {
        try await service.savedBiology(ownerID: "fixture/\(f.id)", projectID: f.id, originalDirectory: f.wrapper,
            storeRoot: f.storeRoot, maximumPixelSize: 128, validate: {})
    }
    private func files(_ root: URL) throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(file.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: file)
        }
        return result
    }

    @Test func realStoredSequencePreviewContainsBasesDoesNotWriteAndRejectsAnOldRevision() async throws {
        let asset = BiologyAsset(title: "Sequence", payload: .sequence([.init(name: "Actual DNA", sequence: "ACGTNNNNACGT")]),
            originalData: Data(">Actual DNA\nACGTNNNNACGT\n".utf8), originalFormat: "fasta")
        let f = try await fixture(asset); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = PersonalContentPreviewService(maximumWorkers: 1), before = try files(f.root)
        let oldRequest = try await request(f, service: service), preview = try await service.preview(oldRequest)
        guard case .text(let text) = preview.content else { Issue.record("Saved sequence produced no real text"); return }
        #expect(text.contains("ACGTNNNNACGT") && !text.contains("This title is not the preview"))
        #expect(try files(f.root) == before, "Preview must not create a store lock, directory, task or derivative file")
        #expect(try await f.store.load(f.id).runs.isEmpty)
        _ = try await f.store.update(f.id, expectedRevision: 2) { project in
            project.assets[0].revision += 1; project.assets[0].payload = .sequence([.init(name: "Updated DNA", sequence: "TTTTCCCCAAAA")])
        }
        do { _ = try await service.preview(oldRequest); Issue.record("Cached preview ignored a changed native HEAD") } catch {}
        let currentRequest = try await request(f, service: service)
        let current = try await service.preview(currentRequest)
        if case .text(let updated) = current.content { #expect(updated.contains("TTTTCCCCAAAA")) }
        else { Issue.record("Updated native sequence has no preview") }
        let absent = f.root.appendingPathComponent("not-created")
        do {
            _ = try await service.savedBiology(ownerID: "missing", projectID: f.id, originalDirectory: f.wrapper, storeRoot: absent, validate: {})
            Issue.record("A missing native store was opened or invented")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: absent.path))
    }

    @Test func realStoredMicroscopySamplesProduceChangingPixelsAndRejectBadDigestOrSymlink() async throws {
        let image = MicroscopyImage(width: 2, height: 2, samples: [0, 1, 2, 3])
        let asset = BiologyAsset(title: "Four real samples", payload: .microscopyImage(image),
            originalData: try BiologyCoding.encode(image), originalFormat: "image.json")
        let f = try await fixture(asset); defer { try? FileManager.default.removeItem(at: f.root) }
        let service = PersonalContentPreviewService(maximumWorkers: 1), before = try files(f.root)
        let firstRequest = try await request(f, service: service)
        let first = try await service.preview(firstRequest)
        guard case .image(let bytes) = first.content else { Issue.record("Saved typed pixels did not produce an image"); return }
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil)), cg = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var samples = [UInt8](repeating: 0, count: 4)
        let bitmap = try #require(CGContext(data: &samples, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 2,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        #expect((samples.min() ?? 255) < 32 && (samples.max() ?? 0) > 224)
        #expect(try files(f.root) == before)
        _ = try await f.store.update(f.id, expectedRevision: 2) { project in
            project.assets[0].revision += 1
            project.assets[0].payload = .microscopyImage(.init(width: 2, height: 2, samples: [3, 2, 1, 0]))
        }
        let secondRequest = try await request(f, service: service)
        let second = try await service.preview(secondRequest)
        if case .image(let changed) = second.content { #expect(previewHash(changed) != previewHash(bytes)) }
        else { Issue.record("Changed native samples have no image") }
        let directory = f.storeRoot.appendingPathComponent(f.id.uuidString.lowercased()), head = directory.appendingPathComponent("HEAD.json")
        let headBytes = try Data(contentsOf: head)
        var header = try #require(JSONSerialization.jsonObject(with: headBytes) as? [String: Any]); header["digest"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: header).write(to: head, options: .atomic)
        do { _ = try await request(f, service: service); Issue.record("A bad native digest generated a preview") } catch {}
        try headBytes.write(to: head, options: .atomic)
        let revision = directory.appendingPathComponent("revisions/3.json"), saved = try Data(contentsOf: revision), outside = f.root.appendingPathComponent("outside.json")
        try saved.write(to: outside); try FileManager.default.removeItem(at: revision)
        try FileManager.default.createSymbolicLink(at: revision, withDestinationURL: outside)
        do { _ = try await request(f, service: service); Issue.record("A native revision link was followed") } catch {}
        let currentHeadBytes = try Data(contentsOf: head), currentOutsideBytes = try Data(contentsOf: outside)
        #expect(currentHeadBytes == headBytes && currentOutsideBytes == saved)
    }

    @Test func savedProteinCoordinatesAndMatrixPreviewShowRealBoundedNativeValuesWithoutWrites() async throws {
        let atoms = (0..<25).map { index in
            StructureAtom(id: index, serial: 10 + index, name: index == 24 ? "NotInFirst24" : "N\(index + 1)", element: "N",
                chain: "A", residue: "GLY", residueNumber: 7 + index,
                x: index == 0 ? 11.125 : Double(index + 100), y: -2.5, z: 3.875)
        }
        let structure = ProteinStructure(atoms: atoms, title: "Not a coordinate thumbnail")
        let protein = BiologyAsset(title: "Do not render this title", payload: .proteinStructure(structure),
            originalData: try BiologyCoding.encode(structure), originalFormat: "typed-structure.json")
        let genes = (0..<13).map { "Gene\($0)" }, cells = (0..<7).map { "Cell\($0)" }
        let rows = genes.indices.map { row in
            [genes[row]] + cells.indices.map { String(Double(row * 1000 + $0) + 0.25) }
        }
        let csv = ([(["gene"] + cells).joined(separator: ",")] + rows.map { $0.joined(separator: ",") }).joined(separator: "\n")
        let matrix = try BiologyImporter.parse(title: "Also not preview content", format: "csv", data: Data(csv.utf8))
        for asset in [protein, matrix] {
            let f = try await fixture(asset); defer { try? FileManager.default.removeItem(at: f.root) }
            let before = try files(f.root), service = PersonalContentPreviewService(maximumWorkers: 1)
            let prepared = try await request(f, service: service), result = try await service.preview(prepared)
            guard case .text(let text) = result.content else { Issue.record("Saved native table produced no text"); continue }
            #expect(result.provenance == .moduleSnapshot && result.byteCost < 32 * 1024)
            if case .proteinStructure = asset.payload {
                #expect(text.contains("1\t10\tN\tN1\tA\tGLY\t7\t\t11.125\t-2.5\t3.875"))
                #expect(text.split(separator: "\n").count == 25 && !text.contains("NotInFirst24"))
                #expect(!text.contains(structure.title) && !text.contains(asset.title))
                #expect(result.detail?.contains("24/25") == true)
            } else {
                #expect(text.contains("Cell0\tCell1\tCell2\tCell3\tCell4\tCell5") && !text.contains("Cell6"))
                #expect(text.contains("Gene1\t1000.25\t1001.25\t1002.25\t1003.25\t1004.25\t1005.25"))
                #expect(text.contains("Gene11\t11000.25") && !text.contains("Gene12\t"))
                #expect(text.split(separator: "\n").count == 13)
                #expect(result.detail?.contains("12/13") == true && result.detail?.contains("6/7") == true)
            }
            #expect(try files(f.root) == before, "A saved table preview must not create tasks, files or analysis results")
            let reopened = try BiologyProjectStore(root: f.storeRoot), stored = try await reopened.load(f.id)
            #expect(stored.assets == [asset] && stored.runs.isEmpty && stored.revision == 2)
        }
    }

    @Test func savedNetworkPreviewUsesActiveEquationsAndInitialAmountsThenFencesChangedRevision() async throws {
        let fallback = try BiologyImporter.parse(title: "Fallback sequence", format: "fasta", data: Data(">fallback\nAACCTTGG\n".utf8))
        let network = BiochemicalNetwork(species: [.init(id: "A", initialAmount: 12.5), .init(id: "B", initialAmount: 3), .init(id: "C", initialAmount: 0)],
            reactions: [.init(id: "r1", reactants: ["A": 1, "B": 2], products: ["C": 1], rateConstant: 0.125),
                        .init(id: "sink", reactants: ["C": 1], products: [:], rateConstant: 4.5)])
        let asset = try BiologyImporter.parse(title: "This is not a reaction", format: "network.json", data: BiologyCoding.encode(network))
        let f = try await fixture(fallback); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.store.update(f.id, expectedRevision: 2) { project in
            project.assets.append(asset); project.activeAssetID = asset.id
        }
        let before = try files(f.root), service = PersonalContentPreviewService(maximumWorkers: 1)
        let oldRequest = try await request(f, service: service), first = try await service.preview(oldRequest)
        guard case .text(let text) = first.content else { Issue.record("Saved network produced no equations"); return }
        #expect(oldRequest.key.objectID == asset.id.uuidString && oldRequest.key.revision == "3:1")
        #expect(text.contains("\"r1\": \"A\" + 2 \"B\" → \"C\"; k = 0.125"))
        #expect(text.contains("\"sink\": \"C\" → ∅; k = 4.5") && text.contains("\"A\" = 12.5"))
        #expect(!text.contains("AACCTTGG") && !text.contains(asset.title))
        #expect(try files(f.root) == before)
        _ = try await f.store.update(f.id, expectedRevision: 3) { project in
            guard let index = project.assets.firstIndex(where: { $0.id == asset.id }),
                  case .biochemicalNetwork(var changed) = project.assets[index].payload else { throw PersonalContentPreviewError.unavailable }
            changed.reactions[0].reactants["B"] = 3; changed.reactions[0].rateConstant = 0.25
            project.assets[index].payload = .biochemicalNetwork(changed); project.assets[index].revision += 1
        }
        do { _ = try await service.preview(oldRequest); Issue.record("An old cached reaction survived a native HEAD change") }
        catch { #expect(error as? PersonalContentPreviewError == .sourceChanged) }
        let currentBefore = try files(f.root), currentRequest = try await request(f, service: service)
        let current = try await service.preview(currentRequest)
        guard case .text(let updated) = current.content else { Issue.record("Current network produced no equations"); return }
        #expect(currentRequest.key.revision == "4:2")
        #expect(updated.contains("\"r1\": \"A\" + 3 \"B\" → \"C\"; k = 0.25") && !updated.contains("k = 0.125"))
        let stored = try await f.store.load(f.id)
        #expect(try files(f.root) == currentBefore && stored.runs.isEmpty)
    }
}
#endif
