// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeBuildingRecords
@testable import FloeBuildingWorkspace

final class BuildingWorkspaceLifecycleTests:XCTestCase {
    func testRequiredExistingProjectDoesNotCreateAMissingRecordsDirectory() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service=BuildingWorkspaceService(projectDirectory:directory,creationPolicy:.requireExisting)
        do{_=try await service.snapshot();XCTFail("Opening missing records must not create a new project")}
        catch BuildingRecordsError.projectNotFound {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
        try await service.finish()
    }
    func testFinishedMountCannotRecreateItsDiscardedDirectory() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service=BuildingWorkspaceService(projectDirectory:root)
        _=try await service.snapshot()
        try await service.finish()
        try FileManager.default.removeItem(at:root)
        do {_=try await service.snapshot();XCTFail("A retired mount must reject late callbacks")}
        catch {XCTAssertEqual(error as? BuildingWorkspaceError,.closed)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testConnectionCloseStillReopensTheSameProject() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service=BuildingWorkspaceService(projectDirectory:root)
        let before=try await service.snapshot()
        try await service.close()
        let after=try await service.snapshot()
        XCTAssertEqual(before.project.id,after.project.id)
        try await service.finish()
        try FileManager.default.removeItem(at:root)
    }
}
