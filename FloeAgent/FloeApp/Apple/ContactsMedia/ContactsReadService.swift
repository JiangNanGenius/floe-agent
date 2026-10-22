// FloeApp — bounded, read-only Contacts access.
//
// SPDX-License-Identifier: MPL-2.0
//
// Official Contacts APIs only. The service fetches exactly the keys the tool
// renders (formatted name, organization, phone numbers, email addresses) and
// never exposes save/delete requests. Enumeration is a bounded scan: the
// caller's scan cap stops the fetch, and a truncated scan is reported rather
// than silently treated as the whole address book. No contact row is written
// to disk or logged.

#if canImport(UIKit) && canImport(Contacts)
import Foundation
@preconcurrency import Contacts
import FloeTools

enum ContactsReadAuthorization: String, Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
    case unavailable

    var canRead: Bool {
        self == .authorized || self == .limited
    }

    var isLimited: Bool {
        self == .limited
    }
}

enum ContactsReadField: String, CaseIterable, Sendable {
    case any
    case name
    case organization
    case phone
    case email
}

struct ContactsReadRecord: Sendable, Equatable {
    var identifier: String
    var displayName: String
    var organization: String
    var phones: [String]
    var emails: [String]
}

struct ContactsReadScan: Sendable, Equatable {
    var records: [ContactsReadRecord]
    var scannedCount: Int
    var truncated: Bool
    var authorization: ContactsReadAuthorization
}

enum ContactsReadError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case authorizationRequired
    case authorizationDenied
    case authorizationRestricted
    case authorizationRequestCancelled
    case authorizationRequestRejected
    case authorizationChanged
    case foregroundRequired
    case cancelled
    case timedOut
    case invalidQuery
    case queryFailed(code: Int)

    var status: String {
        switch self {
        case .unavailable: "contactsUnavailable"
        case .authorizationRequired: "authorizationRequired"
        case .authorizationDenied: "authorizationDenied"
        case .authorizationRestricted: "authorizationRestricted"
        case .authorizationRequestCancelled: "authorizationRequestCancelled"
        case .authorizationRequestRejected: "authorizationRequestRejected"
        case .authorizationChanged: "authorizationChanged"
        case .foregroundRequired: "foregroundRequired"
        case .cancelled: "cancelled"
        case .timedOut: "timedOut"
        case .invalidQuery: "invalidQuery"
        case .queryFailed: "queryFailed"
        }
    }

    var exitStatus: Int32 {
        switch self {
        case .cancelled: 130
        case .timedOut: 124
        case .foregroundRequired, .unavailable, .authorizationChanged: 75
        case .authorizationRequired, .authorizationDenied, .authorizationRestricted,
             .authorizationRequestCancelled, .authorizationRequestRejected:
            77
        case .invalidQuery: 64
        case .queryFailed: 1
        }
    }

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Contacts are not available on this device."
        case .authorizationRequired:
            "Contacts access has not been granted. Keep Floe in the foreground and try again."
        case .authorizationDenied:
            "Contacts access was denied; no contact data was read."
        case .authorizationRestricted:
            "Contacts access is restricted by this device's configuration; no contact data was read."
        case .authorizationRequestCancelled:
            "The Contacts authorization request was cancelled; no contact data was read."
        case .authorizationRequestRejected:
            "The Contacts authorization request did not complete; no contact data was read."
        case .authorizationChanged:
            "Contacts access changed while reading; no partial result was returned."
        case .foregroundRequired:
            "Keep Floe in the foreground while reading contacts."
        case .cancelled:
            "The Contacts read was cancelled."
        case .timedOut:
            "The Contacts read timed out."
        case .invalidQuery:
            "The Contacts query is invalid."
        case .queryFailed:
            "The Contacts read failed."
        }
    }
}

protocol ContactsDirectoryProviding: Sendable {
    var isAvailable: Bool { get }
    var authorization: ContactsReadAuthorization { get }
    func requestAccess(cancellation: CancellationToken) async throws -> ContactsReadAuthorization
    func scan(
        query: String,
        field: ContactsReadField,
        maxScan: Int,
        cancellation: CancellationToken
    ) async throws -> ContactsReadScan
}

/// Counts authorization-scope changes without carrying contact data. The
/// notification callback only bumps a lock-protected generation; the tools
/// include it in the snapshot kind, so an old cursor cannot continue after a
/// limited-selection or deny/allow change.
protocol ContactsAuthorizationEpochProviding: Sendable {
    func epoch(for authorization: ContactsReadAuthorization) -> UInt64
}

final class ContactsAuthorizationMonitor: ContactsAuthorizationEpochProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 1
    private var lastAuthorization: ContactsReadAuthorization?
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        observer = notificationCenter.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.bump()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func epoch(for authorization: ContactsReadAuthorization) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let lastAuthorization, lastAuthorization != authorization {
            generation &+= 1
        }
        lastAuthorization = authorization
        return generation
    }

    func bump() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
}

final class SystemContactsDirectory: ContactsDirectoryProviding, @unchecked Sendable {
    private let store: CNContactStore

    /// Only the four requested output fields (plus the formatter's name
    /// descriptor). No image, address, birthday, note, social profile or
    /// relation keys are fetched.
    private static var keysToFetch: [any CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactIdentifierKey as NSString,
            CNContactOrganizationNameKey as NSString,
            CNContactPhoneNumbersKey as NSString,
            CNContactEmailAddressesKey as NSString
        ]
    }

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    var isAvailable: Bool {
        true
    }

    var authorization: ContactsReadAuthorization {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    func requestAccess(cancellation: CancellationToken) async throws -> ContactsReadAuthorization {
        do {
            _ = try await ContactsMediaRequestRunner.run(
                cancellation: cancellation,
                timeout: 120
            ) {
                try await self.store.requestAccess(for: .contacts)
            }
        } catch ContactsMediaRequestError.cancelled {
            throw ContactsReadError.cancelled
        } catch ContactsMediaRequestError.timedOut {
            throw ContactsReadError.timedOut
        } catch {
            let status = authorization
            if status.canRead { return status }
            throw ContactsReadError.authorizationRequestRejected
        }
        let status = authorization
        if status == .notDetermined {
            throw ContactsReadError.authorizationRequired
        }
        return status
    }

    func scan(
        query: String,
        field: ContactsReadField,
        maxScan: Int,
        cancellation: CancellationToken
    ) async throws -> ContactsReadScan {
        guard isAvailable else { throw ContactsReadError.unavailable }
        let initial = authorization
        guard initial.canRead else { throw Self.authorizationError(initial) }
        if cancellation.isCancelled { throw ContactsReadError.cancelled }

        let cap = min(max(1, maxScan), ContactsMediaOutput.maxSnapshotRows)
        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
        request.unifyResults = true
        request.sortOrder = .givenName
        request.predicate = nil

        var records: [ContactsReadRecord] = []
        var scanned = 0
        var truncated = false
        var wasCancelled = false
        let normalizedQuery = Self.normalized(query)

        do {
            try store.enumerateContacts(with: request) { contact, stop in
                if cancellation.isCancelled {
                    wasCancelled = true
                    stop.pointee = true
                    return
                }
                guard scanned < cap else {
                    truncated = true
                    stop.pointee = true
                    return
                }
                scanned += 1
                let record = Self.record(from: contact)
                if Self.matches(record, query: normalizedQuery, field: field) {
                    records.append(record)
                }
            }
        } catch {
            if wasCancelled || cancellation.isCancelled {
                throw ContactsReadError.cancelled
            }
            let nsError = error as NSError
            if nsError.domain == CNErrorDomain {
                // Documented CNErrorCode authorization values (100 denied,
                // 103 feature disabled by user, 104 feature unavailable).
                switch nsError.code {
                case 100: throw ContactsReadError.authorizationDenied
                case 103: throw ContactsReadError.authorizationRestricted
                case 104: throw ContactsReadError.unavailable
                default: break
                }
            }
            throw ContactsReadError.queryFailed(code: nsError.code)
        }

        if wasCancelled || cancellation.isCancelled { throw ContactsReadError.cancelled }
        let final = authorization
        guard final == initial else { throw ContactsReadError.authorizationChanged }
        return ContactsReadScan(
            records: records,
            scannedCount: scanned,
            truncated: truncated,
            authorization: initial
        )
    }

    private static func map(_ status: CNAuthorizationStatus) -> ContactsReadAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .unavailable
        }
    }

    private static func authorizationError(_ status: ContactsReadAuthorization) -> ContactsReadError {
        switch status {
        case .notDetermined: .authorizationRequired
        case .denied: .authorizationDenied
        case .restricted: .authorizationRestricted
        case .authorized, .limited: .authorizationChanged
        case .unavailable: .unavailable
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private static func matches(
        _ record: ContactsReadRecord,
        query: String,
        field: ContactsReadField
    ) -> Bool {
        guard !query.isEmpty else { return true }
        let name = normalized(record.displayName)
        let organization = normalized(record.organization)
        let phones = normalized(record.phones.joined(separator: " "))
        let emails = normalized(record.emails.joined(separator: " "))
        switch field {
        case .any:
            return name.contains(query)
                || organization.contains(query)
                || phones.contains(query)
                || emails.contains(query)
        case .name:
            return name.contains(query)
        case .organization:
            return organization.contains(query)
        case .phone:
            return phones.contains(query)
        case .email:
            return emails.contains(query)
        }
    }

    private static func record(from contact: CNContact) -> ContactsReadRecord {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let organization = contact.organizationName
        let name = formatted.isEmpty ? organization : formatted
        let phones = contact.phoneNumbers.map { $0.value.stringValue }
        let emails = contact.emailAddresses.compactMap { $0.value as String }
        return ContactsReadRecord(
            identifier: contact.identifier,
            displayName: ContactsMediaText.bounded(name, limit: 120),
            organization: ContactsMediaText.bounded(organization, limit: 120),
            phones: uniqueBounded(phones, itemLimit: 40, maxItems: 3),
            emails: uniqueBounded(emails, itemLimit: 120, maxItems: 3)
        )
    }

    private static func uniqueBounded(
        _ values: [String],
        itemLimit: Int,
        maxItems: Int
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let bounded = ContactsMediaText.bounded(value, limit: itemLimit)
            guard !bounded.isEmpty, seen.insert(bounded).inserted else { continue }
            result.append(bounded)
            if result.count == maxItems { break }
        }
        return result
    }
}
#endif
