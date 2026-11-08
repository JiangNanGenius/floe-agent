import Foundation
import Testing
import FloeCore
@testable import FloeApp
#if canImport(UIKit)
import FloeTools
#endif

@Suite("Scoped library permanent-delete contract")
struct LibraryPermanentDeletionContractTests {
    @Test func irreversibleActionRequiresBothFreshIdentitiesAndExactTrashEntry() throws {
        let base: [String: Any] = ["action": "permanentlyDelete", "projectID": UUID().uuidString,
            "trashEntryID": UUID().uuidString, "expectedIdentity": String(repeating: "a", count: 64),
            "expectedPermanentIdentity": String(repeating: "b", count: 64)]
        let valid = try JSONDecoder().decode(StudioLibraryInput.self, from: JSONSerialization.data(withJSONObject: base))
        try valid.validate(); #expect(valid.isMutation)
        for field in ["projectID", "trashEntryID", "expectedIdentity", "expectedPermanentIdentity"] {
            var invalid = base; invalid.removeValue(forKey: field)
            #expect(throws: Error.self) { try JSONDecoder().decode(StudioLibraryInput.self, from: JSONSerialization.data(withJSONObject: invalid)).validate() }
        }
    }
    @Test func pathsGlobalClearingAndFakeConfirmationCannotGrantAuthority() throws {
        for value: [String: Any] in [["action": "emptyTrash"], ["action": "permanentlyDelete", "path": "/outside"],
                                     ["action": "permanentlyDelete", "confirm": true], ["action": "recentlyDeleted", "expectedPermanentIdentity": String(repeating: "b", count: 64)]] {
            #expect(throws: Error.self) { try JSONDecoder().decode(StudioLibraryInput.self, from: JSONSerialization.data(withJSONObject: value)).validate() }
        }
    }
    @Test func ordinaryListAndRestoreRemainCompatible() throws {
        let list = try JSONDecoder().decode(StudioLibraryInput.self, from: Data(#"{"action":"list","offset":0,"limit":32}"#.utf8)); try list.validate()
        #expect(!list.isMutation)
        let object: [String: Any] = ["action": "restore", "projectID": UUID().uuidString, "trashEntryID": UUID().uuidString, "expectedIdentity": String(repeating: "a", count: 64)]
        let restore = try JSONDecoder().decode(StudioLibraryInput.self, from: JSONSerialization.data(withJSONObject: object)); try restore.validate()
        #expect(restore.isMutation)
    }
    #if canImport(UIKit)
    @Test func permanentActionGetsTheExistingNativeStoreMutationExtent() {
        let specs = TypedMutationContract.specs(for: "studio.library", arguments: ["action": "permanentlyDelete", "projectID": UUID().uuidString])
        #expect(specs.count == 1)
        #expect(specs.first?.storeKey == TypedMutationContract.nativeStudioLibraryStoreKey)
        #expect(TypedMutationContract.specs(for: "studio.library", arguments: ["action": "detail"]).isEmpty)
    }
    #endif
}
