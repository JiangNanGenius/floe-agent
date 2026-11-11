import Foundation

/// The same pinned MMDB fixture bytes used by the package tests are copied
/// into this XCTest bundle by the qualification target's resource phase.
extension Bundle {
    static var module: Bundle { Bundle(for: QualificationResourceAnchor.self) }
}

private final class QualificationResourceAnchor: NSObject {}
