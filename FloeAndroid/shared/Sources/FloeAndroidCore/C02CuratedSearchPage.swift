// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Search pagination is a read projection, never installation authority.
/// Keep its opaque token separate from the frozen decimal payload cursor.
enum C02CuratedSearchPage {
    private struct Token: Codable {
        let version: Int
        let catalogSHA256: String
        let query: String
        let index: Int
    }

    static func normalizedQuery(_ query: String) throws -> String {
        guard query.utf8.count <= 512 else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "curatedSearchQueryTooLong")
        }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func make(cards: [[String: Any]], query: String,
                     catalogSHA256: String, pageToken: String?) throws -> [String: Any] {
        let normalized = try normalizedQuery(query)
        let start: Int
        if let pageToken {
            guard !pageToken.isEmpty, pageToken.utf8.count <= 2_048,
                  let data = Data(base64Encoded: pageToken),
                  let token = try? JSONDecoder().decode(Token.self, from: data),
                  token.version == 1, token.index >= 0, token.index <= cards.count else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "curatedSearchPageToken")
            }
            guard token.catalogSHA256 == catalogSHA256, token.query == normalized else {
                throw ConfigDomainError(code: .staleRevision, reason: "curatedSearchChanged")
            }
            start = token.index
        } else {
            start = 0
        }
        let end = min(cards.count, start + ConfigPageBudget.maximumCatalogResultsPerPage)
        let page = try ConfigPageComposer.compose(
            Array(cards[start..<end]), cursor: nil,
            itemBudget: ConfigPageBudget.maximumPageItemsBytes - 4_096)
        guard let visible = try JSONSerialization.jsonObject(with: page.data) as? [[String: Any]] else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "curatedSearchPageEncode")
        }
        let nextIndex = start + visible.count
        let hasMore = nextIndex < cards.count
        var result: [String: Any] = [
            "query": query, "count": cards.count, "pageCount": visible.count,
            "cards": visible, "hasMore": hasMore,
            "catalogSHA256": catalogSHA256, "nextPageToken": NSNull(),
        ]
        if hasMore {
            let token = try JSONEncoder().encode(Token(
                version: 1, catalogSHA256: catalogSHA256,
                query: normalized, index: nextIndex)).base64EncodedString()
            guard token.utf8.count <= 2_048 else {
                throw ConfigDomainError(code: .payloadTooLarge, reason: "curatedSearchPageTokenTooLarge")
            }
            result["nextPageToken"] = token
        }
        guard let encoded = ConfigJSON.canonicalData(result),
              encoded.count <= ConfigPageBudget.maximumPageItemsBytes else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "curatedSearchPageTooLarge")
        }
        return result
    }
}

/// Whole-reply bounded `skills.list` snapshot pagination.
///
/// The installed rows were historically composed against a row-array budget
/// and then combined with the catalog, curated metadata, pending reviews and
/// settings. That can exceed the frozen 65_536-byte bridge frame even though
/// each individual array claimed to respect `ConfigPageBudget`. This composer
/// measures the ACTUAL serialized UTF-8 of the entire reply after every row is
/// appended, so the complete payload stays within the same 48 KiB page budget
/// used by every other bounded read. Rows remain individually whole and the
/// decimal cursor/index contract is unchanged.
enum C02BoundedSkillSnapshot {
    struct Page {
        let payload: [String: Any]
        let nextCursor: String?
        let hasMore: Bool
    }

    static func compose(base: [String: Any], rows: [[String: Any]], cursor: Int,
                        budget: Int = ConfigPageBudget.maximumPageItemsBytes) throws -> Page {
        guard cursor >= 0, cursor <= rows.count else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "cursorOutOfRange")
        }

        func payload(_ objects: [[String: Any]], next: Int) -> [String: Any] {
            var value = base
            value["skills"] = objects
            value["hasMore"] = next < rows.count
            value["nextCursor"] = next < rows.count ? String(next) : NSNull()
            return value
        }

        let empty = payload([], next: cursor)
        guard let emptyData = ConfigJSON.canonicalData(empty),
              emptyData.count <= budget else {
            // Repeated metadata alone cannot fit. Refuse rather than emit a
            // frame the bridge will drop.
            throw ConfigDomainError(code: .payloadTooLarge, reason: "snapshotBaseTooLarge")
        }

        var objects: [[String: Any]] = []
        objects.reserveCapacity(min(rows.count - cursor,
                                    ConfigPageBudget.maximumItemsPerPage))
        var index = cursor
        while index < rows.count,
              objects.count < ConfigPageBudget.maximumItemsPerPage {
            objects.append(rows[index])
            let candidate = payload(objects, next: index + 1)
            guard let encoded = ConfigJSON.canonicalData(candidate) else {
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "snapshotPageEncode")
            }
            if encoded.count > budget {
                objects.removeLast()
                break
            }
            index += 1
        }
        if objects.isEmpty, cursor < rows.count {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "itemDoesNotFitPage")
        }
        let result = payload(objects, next: index)
        guard let encoded = ConfigJSON.canonicalData(result),
              encoded.count <= budget else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "snapshotPageTooLarge")
        }
        return Page(payload: result,
                    nextCursor: index < rows.count ? String(index) : nil,
                    hasMore: index < rows.count)
    }
}
