// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
#pragma once
#include <functional>
#include <string>
#include <vector>
#include <cstdint>
struct COKitDocument;

// Engine-only implementation stays outside the UIKit translation unit. The
// lookup runs under SolarMutex so a concurrent close cannot invalidate the view.
void FloeImportAttachment(const std::function<COKitDocument *()> &lookupDocument,
                              const std::string &sourceURL, const std::string &packageURL,
                              const std::string &iconURL, const std::string &displayName,
                              const std::string &identifier);

struct FloeEmbeddedAttachment {
    std::string identifier;
    std::string name;
    std::uint64_t byteCount;
};
// Read only live Package objects in the current Office document. Export reads
// the actual embedded bytes, never the original import/recovery sidecar.
std::vector<FloeEmbeddedAttachment> FloeListAttachments(const std::function<COKitDocument *()> &lookupDocument);
void FloeExportAttachment(const std::function<COKitDocument *()> &lookupDocument,
                             const std::string &identifier, const std::string &destinationURL);

// Export to a new private file without changing the live document's URL or format.
void FloeExportDocument(const std::function<COKitDocument *()> &lookupDocument,
                       const std::string &destinationURL, const std::string &format);
