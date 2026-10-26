// FloeApp — bridge to the shared FloeCore settlement primitive.
//
// SPDX-License-Identifier: MPL-2.0
//
// The implementation lives in FloeCore (Foundation-only) so EVERY
// background download owner — job downloads, media artifacts, and later
// the local model catalog and Whisper downloaders — shares ONE corrected
// drain instead of hand-rolling the completion handoff. This bridge keeps
// the App call sites and focused-test names stable.

import Foundation
import FloeCore

typealias BackgroundDownloadEventSettlement = FloeCore.BackgroundDownloadEventSettlement
