// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeTools

extension PersonalContentLibrary {
    /// The actual producer instance owns this root. Record UUIDs and folders
    /// address content inside it; neither is an alternate execution root.
    /// Bookkeeping authority remains with the existing service and runtime.
    func typedServiceStorePaths() -> [String:String] {
        [TypedMutationContract.nativeStudioLibraryStoreKey:root.standardizedFileURL.resolvingSymlinksInPath().path]
    }
}
#endif
