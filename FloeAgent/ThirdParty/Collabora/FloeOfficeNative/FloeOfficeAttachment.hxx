// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
#pragma once
#include <functional>
#include <string>
struct COKitDocument;

// Engine-only implementation stays outside the UIKit translation unit. The
// lookup runs under SolarMutex so a concurrent close cannot invalidate the view.
void FloeImportWordAttachment(const std::function<COKitDocument *()> &lookupDocument,
                              const std::string &sourceURL, const std::string &packageURL,
                              const std::string &iconURL, const std::string &displayName,
                              const std::string &identifier);
