/* SPDX-License-Identifier: MPL-2.0 */
/* Build CMFormatDescriptions from codec configuration records for every
 * codec the data plane supports. Pure helper used by the probe and by
 * session creation. */
#ifndef FLV_FORMAT_DESCRIPTION_H
#define FLV_FORMAT_DESCRIPTION_H

#import "FLVInternal.h"
#include "FLVBitstream.h"

/* codec_config may be NULL for codecs that need no record (jpeg) or when
 * the caller will supply in-band parameter sets later (Annex B H264/HEVC
 * decode). For H264/HEVC the record must be avcC/hvcC. For VP9/AV1 the
 * record is vpcC/av1C; when NULL a standard 8-bit 4:2:0 record is built. */
int flv_create_format_description(uint32_t codec,
                                  const uint8_t *codec_config, size_t codec_config_bytes,
                                  uint32_t width, uint32_t height,
                                  CMFormatDescriptionRef *out);

/* Build from in-band Annex B parameter sets (H264/HEVC decode only). */
int flv_create_format_description_from_param_sets(uint32_t codec,
                                                  const FLVParamSets *ps,
                                                  CMFormatDescriptionRef *out);

#endif /* FLV_FORMAT_DESCRIPTION_H */
