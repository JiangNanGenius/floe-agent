// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeInteriorCore
@testable import FloeBuildingAssets

@MainActor
final class FurnitureAssetImportTests: XCTestCase {
    private func writeCompleteFixture(_ space: FurnitureAssetTestSpace, objText: String? = nil) throws {
        let obj = objText ?? FurnitureAssetFixtures.obj(mtllib: FurnitureAssetFixtures.materialLibraryName)
        try space.write(obj, to: "chair.obj")
        try space.write(FurnitureAssetFixtures.materialLibrary(), to: FurnitureAssetFixtures.materialLibraryName)
        try space.write(FurnitureAssetFixtures.textureData, to: "textures/wood grain.png")
        try space.write("Synthetic license evidence", to: "LICENSE.txt")
        try space.write("Synthetic thumbnail bytes", to: "preview.txt")
    }

    private func importComplete(
        _ space: FurnitureAssetTestSpace,
        library: FurnitureAssetLibrary? = nil,
        assetID: String = "synthetic/armchair",
        version: String = "1",
        sourcePath: String = "chair.obj",
        name: String = "Synthetic Armchair",
        provenance: FurnitureAssetProvenance? = nil,
        declaredDimensions: FurnitureDeclaredDimensions? = FurnitureAssetTestSpace.catalogDimensions(),
        onPhase: FurnitureAssetPhaseObserver? = nil
    ) async throws -> FurnitureAssetVersion {
        let library = library ?? space.library()
        let hasThumbnail = FileManager.default.fileExists(atPath: space.source.appendingPathComponent("preview.txt").path)
        let hasLicense = FileManager.default.fileExists(atPath: space.source.appendingPathComponent("LICENSE.txt").path)
        return try await library.importOBJ(
            sourceRootURL: space.source,
            relativePath: sourcePath,
            assetID: assetID,
            version: version,
            name: name,
            category: "seating",
            provenance: provenance ?? FurnitureAssetTestSpace.syntheticProvenance(),
            declaredDimensions: declaredDimensions,
            sourceBoundsUnit: nil,
            sourceOrientation: .cadYUp,
            thumbnailRelativePath: hasThumbnail ? "preview.txt" : nil,
            licenseFileRelativePath: hasLicense ? "LICENSE.txt" : nil,
            onPhase: onPhase
        )
    }

    func testCompleteOBJMTLTextureClosureAndCorePlacementInput() async throws {
        let space = try FurnitureAssetTestSpace()
        let obj = FurnitureAssetFixtures.obj(mtllib: FurnitureAssetFixtures.materialLibraryName)
        try writeCompleteFixture(space, objText: obj)
        let library = space.library()
        let version = try await importComplete(space, library: library)

        XCTAssertEqual(version.admission, .ready)
        XCTAssertEqual(version.manifest.assetID, "synthetic/armchair")
        XCTAssertEqual(version.manifest.version, "1")
        XCTAssertEqual(version.manifest.name, "Synthetic Armchair")
        XCTAssertEqual(version.manifest.category, "seating")
        XCTAssertEqual(version.manifest.mainFile.sourceRelativePath, "chair.obj")
        XCTAssertEqual(version.manifest.dependencies.count, 2)
        XCTAssertEqual(version.manifest.licenseFile?.role, Optional(FurnitureAssetFileRole.license))
        XCTAssertEqual(version.manifest.thumbnail?.role, Optional(FurnitureAssetFileRole.thumbnail))

        XCTAssertEqual(version.manifest.sourceBounds.minimum.x, 0, accuracy: 1e-9)
        XCTAssertEqual(version.manifest.sourceBounds.minimum.y, 0, accuracy: 1e-9)
        XCTAssertEqual(version.manifest.sourceBounds.minimum.z, 0, accuracy: 1e-9)
        XCTAssertEqual(version.manifest.sourceBounds.maximum.x, 2, accuracy: 1e-9)
        XCTAssertEqual(version.manifest.sourceBounds.maximum.y, 4, accuracy: 1e-9)
        XCTAssertEqual(version.manifest.sourceBounds.maximum.z, 1.5, accuracy: 1e-9)

        let mtlHash = FurnitureAssetTestSpace.sha256(FurnitureAssetFixtures.materialLibrary())
        let textureHash = FurnitureAssetTestSpace.sha256(FurnitureAssetFixtures.textureData)
        XCTAssertEqual(version.manifest.dependencySHA256[FurnitureAssetFixtures.materialLibraryName], mtlHash)
        XCTAssertEqual(version.manifest.dependencySHA256["textures/wood grain.png"], textureHash)
        XCTAssertEqual(version.manifest.mainFile.sha256, FurnitureAssetTestSpace.sha256(obj))

        let bundle = try await library.open(assetID: "synthetic/armchair", version: "1", verifyFiles: true)
        let verification = try bundle.verify()
        XCTAssertEqual(verification.admission, .ready)
        XCTAssertEqual(verification.verifiedFileCount, 5)
        XCTAssertEqual(verification.verifiedDependencyCount, 2)
        XCTAssertEqual(verification.totalBytes, Data(obj.utf8).count
            + Data(FurnitureAssetFixtures.materialLibrary().utf8).count
            + FurnitureAssetFixtures.textureData.count
            + Data("Synthetic license evidence".utf8).count
            + Data("Synthetic thumbnail bytes".utf8).count)

        let mainURL = try bundle.mainFileURL()
        XCTAssertTrue(mainURL.path.hasSuffix("/files/chair.obj"))
        XCTAssertEqual(try Data(contentsOf: mainURL), Data(obj.utf8))

        let plan = try bundle.placementPlan(
            instanceID: UUID(),
            pose: FurnitureAssetTestSpace.pose(),
            sizing: .catalogDimensions(FurnitureAssetTestSpace.catalogDimensions().millimetres, allowNonUniformScaling: true)
        )
        XCTAssertEqual(plan.dimensionsMM.widthMM, 2_000, accuracy: 1e-7)
        XCTAssertEqual(plan.dimensionsMM.depthMM, 1_500, accuracy: 1e-7)
        XCTAssertEqual(plan.dimensionsMM.heightMM, 1_000, accuracy: 1e-7)
        XCTAssertEqual(plan.sizeBasis, "catalog-declared-size")
        XCTAssertNil(plan.sourceMillimetresPerUnit)

        let explicitPlan = try bundle.placementPlan(
            instanceID: UUID(),
            pose: FurnitureAssetTestSpace.pose(),
            sizing: .sourceUnits(millimetresPerUnit: 10)
        )
        XCTAssertEqual(explicitPlan.dimensionsMM.widthMM, 20, accuracy: 1e-7)
        XCTAssertEqual(explicitPlan.dimensionsMM.heightMM, 40, accuracy: 1e-7)
        XCTAssertGreaterThan(abs(explicitPlan.dimensionsMM.heightMM - 1_000), 100)

        let summaries = try await library.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.admission, Optional(FurnitureAssetAdmission.ready))
        let armSearch = try await library.search(query: "arm")
        let seatingSearch = try await library.search(query: "", category: "seating")
        let tableSearch = try await library.search(query: "", category: "tables")
        XCTAssertEqual(armSearch.count, 1)
        XCTAssertEqual(seatingSearch.count, 1)
        XCTAssertEqual(tableSearch.count, 0)

        let pin = try await library.pin(assetID: "synthetic/armchair", version: "1")
        XCTAssertEqual(pin.sourceSHA256, version.manifest.mainFile.sha256)
        XCTAssertEqual(pin.dependencySHA256, version.manifest.dependencySHA256)
        let reopened = try await library.open(pin: pin)
        XCTAssertEqual(reopened.manifest, version.manifest)
    }

    func testMissingTextureIsExplicitNeedsRepairAndIsNotPlaceable() async throws {
        let space = try FurnitureAssetTestSpace()
        try space.write(FurnitureAssetFixtures.obj(), to: "chair.obj")
        try space.write(
            FurnitureAssetFixtures.materialLibrary(texture: "textures/missing.png"),
            to: FurnitureAssetFixtures.materialLibraryName
        )
        let library = space.library()
        let version = try await importComplete(space, library: library)

        XCTAssertEqual(version.admission, .needsRepair)
        XCTAssertEqual(version.manifest.issues.count, 1)
        XCTAssertEqual(version.manifest.issues.first?.kind, Optional(FurnitureAssetIssueKind.missingDependency))
        XCTAssertEqual(version.manifest.issues.first?.role, Optional(FurnitureAssetFileRole.texture))
        XCTAssertEqual(version.manifest.dependencies.count, 1)
        XCTAssertEqual(version.manifest.dependencies.first?.role, Optional(FurnitureAssetFileRole.materialLibrary))
        XCTAssertFalse(version.manifest.dependencies.contains { $0.sourceRelativePath == "textures/missing.png" })
        let versionRoot = space.libraryRoot
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(FurnitureAssetTestSpace.sha256("synthetic/armchair"), isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(FurnitureAssetTestSpace.sha256("1"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: versionRoot.appendingPathComponent("files/textures/missing.png").path
        ))

        let summaries = try await library.list()
        XCTAssertEqual(summaries.first?.admission, Optional(FurnitureAssetAdmission.needsRepair))
        XCTAssertEqual(summaries.first?.issueCount, Optional(1))

        let bundle = try await library.open(assetID: "synthetic/armchair", version: "1", verifyFiles: true)
        XCTAssertEqual(try bundle.verify().admission, .needsRepair)
        do {
            _ = try bundle.mainFileURL()
            XCTFail("A needs-repair asset must not expose a native import URL as admitted")
        } catch let error as FurnitureAssetLibraryError {
            guard case .notAdmitted = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        do {
            _ = try await library.pin(assetID: "synthetic/armchair", version: "1")
            XCTFail("A needs-repair asset must not be pinnable")
        } catch let error as FurnitureAssetLibraryError {
            guard case .notAdmitted = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testAbsoluteTraversalAndSymlinkTextureReferencesAreNeverFollowed() async throws {
        let space = try FurnitureAssetTestSpace()
        let outside = space.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("outside secret".utf8).write(to: secret)

        try space.write(FurnitureAssetFixtures.obj(), to: "chair.obj")
        try space.write(
            """
            newmtl synthetic
            map_Kd ../outside/secret.txt
            map_Kd /absolute/secret.txt
            map_Kd textures/secret.txt
            """,
            to: FurnitureAssetFixtures.materialLibraryName
        )
        try space.write("not used", to: "textures/.keep")
        try FileManager.default.createSymbolicLink(
            at: space.source.appendingPathComponent("textures/secret.txt"),
            withDestinationURL: secret
        )

        let library = space.library()
        let version = try await importComplete(space, library: library)
        XCTAssertEqual(version.admission, .needsRepair)
        XCTAssertGreaterThanOrEqual(version.manifest.issues.count, 3)
        XCTAssertTrue(version.manifest.issues.allSatisfy { $0.kind == .unsafeReference })
        XCTAssertEqual(version.manifest.dependencies.count, 1)
        XCTAssertEqual(version.manifest.dependencies.first?.role, Optional(FurnitureAssetFileRole.materialLibrary))
        XCTAssertFalse(version.manifest.dependencies.contains { $0.sourceRelativePath.contains("..") })
        XCTAssertFalse(version.manifest.dependencies.contains { $0.sourceRelativePath.hasPrefix("/") })

        let bundle = try await library.open(assetID: "synthetic/armchair", version: "1", verifyFiles: true)
        XCTAssertEqual(try bundle.verify().verifiedFileCount, 2)
        do {
            _ = try bundle.mainFileURL()
            XCTFail("An unsafe dependency closure must not be admitted")
        } catch let error as FurnitureAssetLibraryError {
            guard case .notAdmitted = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testQuotedAndUnquotedSpacesAndCommonMapOptions() async throws {
        let space = try FurnitureAssetTestSpace()
        try space.write(
            FurnitureAssetFixtures.obj(mtllib: "\"\(FurnitureAssetFixtures.materialLibraryName)\""),
            to: "quoted.obj"
        )
        try space.write(FurnitureAssetFixtures.materialLibrary(), to: FurnitureAssetFixtures.materialLibraryName)
        try space.write(FurnitureAssetFixtures.textureData, to: "textures/wood grain.png")

        let library = space.library()
        let quoted = try await library.importOBJ(
            sourceRootURL: space.source,
            relativePath: "quoted.obj",
            assetID: "synthetic/quoted",
            version: "1",
            name: "Quoted Chair",
            category: "seating",
            provenance: FurnitureAssetTestSpace.syntheticProvenance(),
            sourceOrientation: .cadYUp
        )
        XCTAssertEqual(quoted.admission, .ready)
        XCTAssertEqual(quoted.manifest.dependencies.count, 2)
        XCTAssertEqual(quoted.manifest.dependencySHA256["textures/wood grain.png"], FurnitureAssetTestSpace.sha256(FurnitureAssetFixtures.textureData))

        try space.write(
            FurnitureAssetFixtures.obj(mtllib: FurnitureAssetFixtures.materialLibraryName),
            to: "unquoted.obj"
        )
        try space.write(
            FurnitureAssetFixtures.materialLibraryWithoutOptions(),
            to: FurnitureAssetFixtures.materialLibraryName
        )
        let unquoted = try await library.importOBJ(
            sourceRootURL: space.source,
            relativePath: "unquoted.obj",
            assetID: "synthetic/unquoted",
            version: "1",
            name: "Unquoted Chair",
            category: "seating",
            provenance: FurnitureAssetTestSpace.syntheticProvenance(),
            sourceOrientation: .cadYUp
        )
        XCTAssertEqual(unquoted.admission, .ready)
        XCTAssertEqual(unquoted.manifest.dependencies.count, 2)
        XCTAssertEqual(unquoted.manifest.dependencySHA256["textures/wood grain.png"], FurnitureAssetTestSpace.sha256(FurnitureAssetFixtures.textureData))
    }

    func testMalformedGeometryAndNonFiniteNumbersPublishNoVersion() async throws {
        let space = try FurnitureAssetTestSpace()
        try space.write(
            """
            v nan 0 0
            v 0 1 0
            f 1 2 1
            """,
            to: "bad.obj"
        )
        let library = space.library()
        do {
            _ = try await library.importOBJ(
                sourceRootURL: space.source,
                relativePath: "bad.obj",
                assetID: "synthetic/bad",
                version: "1",
                name: "Bad Chair",
                category: nil,
                provenance: FurnitureAssetTestSpace.syntheticProvenance(),
                sourceOrientation: .cadYUp
            )
            XCTFail("Non-finite geometry must be refused")
        } catch let error as FurnitureAssetLibraryError {
            guard case .invalidOBJ = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        let listed = try await library.list()
        XCTAssertTrue(listed.isEmpty)
    }

    func testCancellationRemovesStagingAndBudgetRefusesPublication() async throws {
        let space = try FurnitureAssetTestSpace()
        try writeCompleteFixture(space)
        let library = space.library()
        do {
            _ = try await importComplete(space, library: library, onPhase: { phase in
                if phase == .verifyingStaging {
                    throw CancellationError()
                }
            })
            XCTFail("Cancellation must be propagated")
        } catch is CancellationError {
            // Expected.
        }
        let listed = try await library.list()
        XCTAssertTrue(listed.isEmpty)
        let staging = space.libraryRoot.appendingPathComponent(".staging", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty)

        let cancelledVersion = try await importComplete(space, library: library)
        XCTAssertEqual(cancelledVersion.admission, .ready)

        let limited = space.library(limits: .init(maximumVertices: 3))
        do {
            _ = try await limited.importOBJ(
                sourceRootURL: space.source,
                relativePath: "chair.obj",
                assetID: "synthetic/budget",
                version: "1",
                name: "Budget Chair",
                category: nil,
                provenance: FurnitureAssetTestSpace.syntheticProvenance(),
                sourceOrientation: .cadYUp
            )
            XCTFail("The vertex budget must be enforced")
        } catch let error as FurnitureAssetLibraryError {
            guard case .budgetExceeded = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        let budgetVersions = try await limited.versions(for: "synthetic/budget")
        XCTAssertTrue(budgetVersions.isEmpty)

        let fileLimited = space.library(limits: .init(maximumFiles: 2))
        do {
            _ = try await fileLimited.importOBJ(
                sourceRootURL: space.source,
                relativePath: "chair.obj",
                assetID: "synthetic/file-budget",
                version: "1",
                name: "File Budget Chair",
                category: nil,
                provenance: FurnitureAssetTestSpace.syntheticProvenance(),
                sourceOrientation: .cadYUp
            )
            XCTFail("The file budget must be enforced")
        } catch let error as FurnitureAssetLibraryError {
            guard case .budgetExceeded = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        let byteLimited = space.library(limits: .init(
            maximumTotalBytes: 128, maximumMainFileBytes: 16,
            maximumDependencyBytes: 128, maximumMetadataBytes: 128))
        do {
            _ = try await byteLimited.importOBJ(
                sourceRootURL: space.source,
                relativePath: "chair.obj",
                assetID: "synthetic/byte-budget",
                version: "1",
                name: "Byte Budget Chair",
                category: nil,
                provenance: FurnitureAssetTestSpace.syntheticProvenance(),
                sourceOrientation: .cadYUp
            )
            XCTFail("The main-file byte budget must be enforced")
        } catch let error as FurnitureAssetLibraryError {
            guard case .sourceFileTooLarge = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        let byteBudgetVersions = try await byteLimited.versions(for: "synthetic/byte-budget")
        XCTAssertTrue(byteBudgetVersions.isEmpty)
    }
}
