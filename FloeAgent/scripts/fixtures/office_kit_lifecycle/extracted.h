// Extraction contract for the kit callback lifecycle harness.
//
// test_office_kit_lifecycle.py stages the pinned kit/Kit.cpp (original and
// with kitCallbackLifecycleOverlay applied) and writes:
//   push.inc.h          - verbatim extraction of
//                         KitSocketPoll::pushToMainThread for this variant
//   kit_identity.inc.h  - the patched pollCallback identity-store statement,
//                         or an explanatory comment for the original
//   add_callback.inc.h  - verbatim extraction of pinned net/Socket.hpp
//                         SocketPoll::addCallback
// The driver compiles exactly one variant; the extracted statements are the
// only production code in the translation unit.
#pragma once

#include "mock_types.h"

namespace mock {

// Out-of-class definition of KitSocketPoll::pushToMainThread extracted from
// this variant's kit/Kit.cpp by the test; do not edit by hand.
#include "push.inc.h"

} // namespace mock
