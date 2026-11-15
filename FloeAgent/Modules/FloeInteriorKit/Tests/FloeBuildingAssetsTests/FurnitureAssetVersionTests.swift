// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeInteriorCore
@testable import FloeBuildingAssets

@MainActor
final class FurnitureAssetVersionTests: XCTestCase {
    private func fill(_ space: FurnitureAssetTestSpace) throws {
        try space.write(FurnitureAssetFixtures.obj(), to: "chair.obj")
        try space.write(FurnitureAssetFixtures.materialLibrary(), to: FurnitureAssetFixtures.materialLibraryName)
        try space.write(FurnitureAssetFixtures.textureData, to: "textures/wood grain.png")
    }

    private func importVersion(
        _ space: FurnitureAssetTestSpace,
        _ library: FurnitureAssetLibrary,
        version: String,
        name: String = "Synthetic Armchair",
        declaredDimensions: FurnitureDeclaredDimensions? = FurnitureAssetTestSpace.catalogDimensions(),
        provenance: FurnitureAssetProvenance? = nil
    ) async throws -> FurnitureAssetVersion {
        try await library.importOBJ(
            sourceRootURL: space.source,
            relativePath: "chair.obj",
            assetID: "synthetic/armchair",
            version: version,
            name: name,
            category: "seating",
            provenance: provenance ?? FurnitureAssetTestSpace.syntheticProvenance(),
            declaredDimensions: declaredDimensions,
            sourceBoundsUnit: nil,
            sourceOrientation: .cadYUp
        )
    }

    private func versionRoot(_ space: FurnitureAssetTestSpace, assetID: String = "synthetic/armchair", version: String = "1") -> URL {
        space.libraryRoot
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(FurnitureAssetTestSpace.sha256(assetID), isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(FurnitureAssetTestSpace.sha256(version), isDirectory: true)
    }

    func testTamperedFileAndPinnedManifestAreDetected() async throws {
        let space = try FurnitureAssetTestSpace()
        try fill(space)
        let library = space.library()
        let version = try await importVersion(space, library, version: "1")
        let pin = try await library.pin(assetID: "synthetic/armchair", version: "1")
        let bundle = try await library.open(assetID: "synthetic/armchair", version: "1")
        let mainURL = try bundle.mainFileURL()
        try Data("tampered bytes".utf8).write(to: mainURL, options: .atomic)

        XCTAssertThrowsError(try bundle.verify())
        do {
            _ = try await library.open(assetID: "synthetic/armchair", version: "1", verifyFiles: true)
            XCTFail("A tampered stored file must not open as verified")
        } catch let error as FurnitureAssetLibraryError {
            guard case .hashMismatch = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        // A different tamper: alter the manifest itself. The library's own
        // manifest hash is recomputed on open, so the project pin is the
        // authority that must reject the changed bytes.
        let manifestURL = versionRoot(space).appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["name"] = "Tampered Armchair"
        let tamperedManifest = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try tamperedManifest.write(to: manifestURL, options: .atomic)
        do {
            _ = try await library.open(pin: pin)
            XCTFail("A changed manifest must not match the project pin")
        } catch let error as FurnitureAssetLibraryError {
            guard case .hashMismatch = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(version.manifest.name, "Synthetic Armchair")
    }

    func testIdempotentReimportAndDifferentManifestVersionConflict() async throws {
        let space = try FurnitureAssetTestSpace()
        try fill(space)
        let library = space.library()
        let first = try await importVersion(space, library, version: "1")
        let firstBundle = try await library.open(assetID: "synthetic/armchair", version: "1")
        let firstMain = try firstBundle.mainFileURL()
        let firstBytes = try Data(contentsOf: firstMain)

        let again = try await importVersion(space, library, version: "1")
        XCTAssertEqual(again.manifestSHA256, first.manifestSHA256)
        let versionsAfterRepeat = try await library.versions(for: "synthetic/armchair")
        XCTAssertEqual(versionsAfterRepeat.count, 1)

        do {
            _ = try await importVersion(space, library, version: "1", name: "Different Armchair")
            XCTFail("A different manifest must not overwrite an immutable version")
        } catch let error as FurnitureAssetLibraryError {
            guard case .versionConflict(let assetID, let version) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(assetID, "synthetic/armchair")
            XCTAssertEqual(version, "1")
        }
        let reopened = try await library.open(assetID: "synthetic/armchair", version: "1")
        XCTAssertEqual(try Data(contentsOf: reopened.mainFileURL()), firstBytes)
        XCTAssertEqual(reopened.manifest.name, "Synthetic Armchair")
    }

    func testOldPinSurvivesUpdateAndComparisonIsExplicit() async throws {
        let space = try FurnitureAssetTestSpace()
        try fill(space)
        let library = space.library()
        let first = try await importVersion(space, library, version: "1")
        let firstPin = try await library.pin(assetID: "synthetic/armchair", version: "1")

        let v2OBJ = FurnitureAssetFixtures.obj(vertices: [
            "v 0 0 0",
            "v 2 0 0",
            "v 0 4 0",
            "v 0 0 1.5",
            "v 3 4 2"
        ])
        try space.write(v2OBJ, to: "chair.obj")
        let v2Texture = Data("different synthetic texture bytes".utf8)
        try space.write(v2Texture, to: "textures/wood grain.png")
        let second = try await importVersion(
            space,
            library,
            version: "2",
            name: "Synthetic Armchair v2",
            declaredDimensions: .init(width: 2_100, depth: 1_600, height: 1_100, unit: .millimetre)
        )

        let versionsAfterUpdate = try await library.versions(for: "synthetic/armchair")
        XCTAssertEqual(versionsAfterUpdate.count, 2)
        let oldBundle = try await library.open(pin: firstPin)
        XCTAssertEqual(oldBundle.manifestSHA256, first.manifestSHA256)
        XCTAssertEqual(oldBundle.manifest.name, "Synthetic Armchair")
        XCTAssertEqual(oldBundle.manifest.declaredDimensions, FurnitureAssetTestSpace.catalogDimensions())
        XCTAssertEqual(
            try Data(contentsOf: oldBundle.mainFileURL()),
            Data(FurnitureAssetFixtures.obj().utf8)
        )

        let difference = try await library.compare(assetID: "synthetic/armchair", from: "1", to: "2")
        XCTAssertTrue(difference.hasChanges)
        XCTAssertTrue(difference.mainFileChanged)
        XCTAssertEqual(difference.fromVersion, "1")
        XCTAssertEqual(difference.toVersion, "2")
        XCTAssertTrue(difference.nameChanged)
        XCTAssertTrue(difference.declaredDimensionsChanged)
        XCTAssertTrue(difference.sourceBoundsChanged)
        XCTAssertFalse(difference.admissionChanged)
        let textureDifference = difference.dependencyDifferences.first {
            $0.sourceRelativePath == "textures/wood grain.png"
        }
        XCTAssertEqual(textureDifference?.change, Optional(FurnitureAssetDependencyChange.contentChanged))
        XCTAssertEqual(textureDifference?.fromSHA256, Optional(FurnitureAssetTestSpace.sha256(FurnitureAssetFixtures.textureData)))
        XCTAssertEqual(textureDifference?.toSHA256, Optional(FurnitureAssetTestSpace.sha256(v2Texture)))
        XCTAssertEqual(second.manifest.declaredDimensions?.width ?? -1, 2_100, accuracy: 1e-7)
        XCTAssertNil(second.manifest.licenseFile)
        XCTAssertNil(second.manifest.thumbnail)
    }

    func testOfflineCopyVerifiesAfterLibraryAndSourceRemovalWithIndependentInstances() async throws {
        let space = try FurnitureAssetTestSpace()
        try fill(space)
        let library = space.library()
        let version = try await importVersion(space, library, version: "1")
        let pin = try await library.pin(assetID: "synthetic/armchair", version: "1")
        let destination = space.root.appendingPathComponent("private-project/offline-armchair", isDirectory: true)
        let copy = try await library.makeOfflineCopy(pin: pin, to: destination)
        XCTAssertEqual(copy.pin, pin)
        XCTAssertEqual(copy.manifest, version.manifest)
        let copyVerification = try copy.verify()
        XCTAssertEqual(copyVerification.admission, .ready)

        let pinText = try String(contentsOf: copy.rootURL.appendingPathComponent("pin.json"), encoding: .utf8)
        XCTAssertFalse(pinText.contains(space.libraryRoot.path))

        let mainURL = try copy.mainFileURL()
        XCTAssertEqual(try Data(contentsOf: mainURL), Data(FurnitureAssetFixtures.obj().utf8))
        let plan = try copy.placementPlan(
            instanceID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            pose: FurnitureAssetTestSpace.pose(),
            sizing: .catalogDimensions(FurnitureAssetTestSpace.catalogDimensions().millimetres, allowNonUniformScaling: true)
        )
        XCTAssertEqual(plan.dimensionsMM.widthMM, 2_000, accuracy: 1e-7)
        XCTAssertEqual(plan.dimensionsMM.heightMM, 1_000, accuracy: 1e-7)

        var secondPose = FurnitureAssetTestSpace.pose()
        secondPose.planXMM += 500
        let secondPlan = try copy.placementPlan(
            instanceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            pose: secondPose,
            sizing: .catalogDimensions(FurnitureAssetTestSpace.catalogDimensions().millimetres, allowNonUniformScaling: true)
        )
        XCTAssertEqual(plan.assetID, secondPlan.assetID)
        XCTAssertEqual(plan.assetVersion, secondPlan.assetVersion)
        XCTAssertNotEqual(plan.instanceID, secondPlan.instanceID)
        XCTAssertEqual(secondPlan.envelopeInNativeMM.minimum.x - plan.envelopeInNativeMM.minimum.x, 500, accuracy: 1e-7)

        space.removeLibrary()
        try? FileManager.default.removeItem(at: space.source)
        let reopenedVerification = try copy.verify()
        XCTAssertEqual(reopenedVerification.admission, .ready)
        XCTAssertEqual(try Data(contentsOf: copy.mainFileURL()), Data(FurnitureAssetFixtures.obj().utf8))
        let reopenedPlan = try copy.placementPlan(
            instanceID: UUID(),
            pose: FurnitureAssetTestSpace.pose(),
            sizing: .catalogDimensions(FurnitureAssetTestSpace.catalogDimensions().millimetres, allowNonUniformScaling: true)
        )
        XCTAssertEqual(reopenedPlan.dimensionsMM.heightMM, 1_000, accuracy: 1e-7)
        do {
            _ = try await library.open(pin: pin)
            XCTFail("The removed library must not be readable")
        } catch let error as FurnitureAssetLibraryError {
            guard case .notFound = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testOfflineCopyDoesNotOverwriteAnExistingDestination() async throws {
        let space = try FurnitureAssetTestSpace()
        try fill(space)
        let library = space.library()
        _ = try await importVersion(space, library, version: "1")
        let pin = try await library.pin(assetID: "synthetic/armchair", version: "1")
        let destination = space.root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        do {
            _ = try await library.makeOfflineCopy(pin: pin, to: destination)
            XCTFail("An existing destination must not be overwritten")
        } catch let error as FurnitureAssetLibraryError {
            guard case .destinationExists = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testUserProvidedPermissionsAreRecordedButDoNotBlockPrivateUse() async throws {
        let space = try FurnitureAssetTestSpace()
        try fill(space)
        let library = space.library()
        let version = try await importVersion(
            space,
            library,
            version: "1",
            provenance: .userProvided(source: "User-supplied synthetic fixture")
        )
        XCTAssertEqual(version.admission, .ready)
        XCTAssertEqual(version.manifest.provenance.license.evidence, .userProvided)
        XCTAssertEqual(version.manifest.provenance.license.mayHost, .unknown)
        XCTAssertEqual(version.manifest.provenance.license.mayShareInProject, .unknown)

        let pin = try await library.pin(assetID: "synthetic/armchair", version: "1")
        let userBundle = try await library.open(pin: pin)
        let plan = try userBundle.placementPlan(
            instanceID: UUID(),
            pose: FurnitureAssetTestSpace.pose(),
            sizing: .catalogDimensions(FurnitureAssetTestSpace.catalogDimensions().millimetres, allowNonUniformScaling: true)
        )
        XCTAssertEqual(plan.dimensionsMM.heightMM, 1_000, accuracy: 1e-7)
        let destination = space.root.appendingPathComponent("private-offline", isDirectory: true)
        let copy = try await library.makeOfflineCopy(pin: pin, to: destination)
        let copyVerification = try copy.verify()
        XCTAssertEqual(copyVerification.admission, .ready)
        XCTAssertEqual(copy.pin, pin)
    }

    func testTwoLibrariesPublishingSameVersionUseTheRealFileLock() async throws {
        let space = try FurnitureAssetTestSpace()
        try space.write("v 0 0 0\nv 1 0 0\nv 0 1 1\nf 1 2 3\n", to: "a.obj")
        try space.write("v 0 0 0\nv 2 0 0\nv 0 2 2\nf 1 2 3\n", to: "b.obj")
        let firstLibrary = space.library()
        let secondLibrary = space.library()
        let sourceRoot = space.source
        let provenance = FurnitureAssetTestSpace.syntheticProvenance()

        let outcomes = await withTaskGroup(of: String.self) { group in
            group.addTask {
                do {
                    _ = try await firstLibrary.importOBJ(
                        sourceRootURL: sourceRoot,
                        relativePath: "a.obj",
                        assetID: "synthetic/shared",
                        version: "1",
                        name: "Shared A",
                        category: nil,
                        provenance: provenance,
                        sourceOrientation: .cadYUp
                    )
                    return "success"
                } catch let error as FurnitureAssetLibraryError {
                    if case .versionConflict = error { return "conflict" }
                    return "error"
                } catch {
                    return "error"
                }
            }
            group.addTask {
                do {
                    _ = try await secondLibrary.importOBJ(
                        sourceRootURL: sourceRoot,
                        relativePath: "b.obj",
                        assetID: "synthetic/shared",
                        version: "1",
                        name: "Shared B",
                        category: nil,
                        provenance: provenance,
                        sourceOrientation: .cadYUp
                    )
                    return "success"
                } catch let error as FurnitureAssetLibraryError {
                    if case .versionConflict = error { return "conflict" }
                    return "error"
                } catch {
                    return "error"
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values.sorted()
        }
        XCTAssertEqual(outcomes, ["conflict", "success"])
        let stored = try await firstLibrary.open(assetID: "synthetic/shared", version: "1", verifyFiles: true)
        XCTAssertEqual(try stored.verify().verifiedFileCount, 1)
        let storedText = try String(contentsOf: stored.mainFileURL(), encoding: .utf8)
        XCTAssertTrue(storedText == "v 0 0 0\nv 1 0 0\nv 0 1 1\nf 1 2 3\n"
            || storedText == "v 0 0 0\nv 2 0 0\nv 0 2 2\nf 1 2 3\n")
    }
}
