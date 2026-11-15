/* SPDX-License-Identifier: MPL-2.0 */
/* The frozen public header is header-only for consumers. This one translation
 * unit keeps the SwiftPM target valid and exposes the exact ABI version for
 * build diagnostics; it adds no public function or layout. */
#include "floe_linux_video.h"

const unsigned flv_public_abi_version = FLV_ABI_VERSION;
