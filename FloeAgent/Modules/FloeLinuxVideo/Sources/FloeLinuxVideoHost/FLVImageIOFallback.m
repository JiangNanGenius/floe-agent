/* SPDX-License-Identifier: MPL-2.0 */
#import "FLVImageIOFallback.h"
#import "FLVInternal.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <stdbool.h>

/* Fixed JPEG quality for the fallback (0..1). The ABI's bitrate has no JPEG
 * meaning; inventing a bitrate->quality mapping would be a false promise. */
static const double kFLVJPEGQuality = 0.8;

static int flv_validate(uint32_t width, uint32_t height) {
    if (!width || !height || (width & 1u) || (height & 1u)) return FLV_INVALID;
    if (width > 8192u || height > 8192u) return FLV_LIMIT;
    return FLV_OK;
}

static CVPixelBufferRef flv_create_pixel_buffer(uint32_t width, uint32_t height, OSType fmt) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };
    CVPixelBufferRef pb = NULL;
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    return cr == kCVReturnSuccess ? pb : NULL;
}

/* Public NV12 -> BGRA transfer. Returns a +1 BGRA buffer. */
static CVPixelBufferRef flv_nv12_to_bgra(CVPixelBufferRef nv12) {
    uint32_t width = (uint32_t)CVPixelBufferGetWidth(nv12);
    uint32_t height = (uint32_t)CVPixelBufferGetHeight(nv12);
    CVPixelBufferRef bgra = flv_create_pixel_buffer(width, height,
        kCVPixelFormatType_32BGRA);
    if (!bgra) return NULL;
    VTPixelTransferSessionRef transfer = NULL;
    OSStatus err = VTPixelTransferSessionCreate(NULL, &transfer);
    if (err == noErr && transfer) {
        err = VTPixelTransferSessionTransferImage(transfer, nv12, bgra);
        VTPixelTransferSessionInvalidate(transfer);
        CFRelease(transfer);
    }
    if (err != noErr) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    return bgra;
}

/* Public BGRA -> NV12 transfer. Returns a +1 NV12 buffer. */
static CVPixelBufferRef flv_bgra_to_nv12(CVPixelBufferRef bgra) {
    uint32_t width = (uint32_t)CVPixelBufferGetWidth(bgra);
    uint32_t height = (uint32_t)CVPixelBufferGetHeight(bgra);
    CVPixelBufferRef nv12 = flv_create_pixel_buffer(width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (!nv12) return NULL;
    VTPixelTransferSessionRef transfer = NULL;
    OSStatus err = VTPixelTransferSessionCreate(NULL, &transfer);
    if (err == noErr && transfer) {
        err = VTPixelTransferSessionTransferImage(transfer, bgra, nv12);
        VTPixelTransferSessionInvalidate(transfer);
        CFRelease(transfer);
    }
    if (err != noErr) {
        CVPixelBufferRelease(nv12);
        return NULL;
    }
    return nv12;
}

/* Copy a CGImage into a BGRA CVPixelBuffer with the public bitmap context.
 * Context row 0 is the top row after the explicit vertical flip. */
static CVPixelBufferRef flv_cgimage_to_bgra(CGImageRef image, uint32_t width, uint32_t height) {
    CVPixelBufferRef bgra = flv_create_pixel_buffer(width, height,
        kCVPixelFormatType_32BGRA);
    if (!bgra) return NULL;
    if (CVPixelBufferLockBaseAddress(bgra, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    size_t stride = CVPixelBufferGetBytesPerRow(bgra);
    void *base = CVPixelBufferGetBaseAddress(bgra);
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(base, width, height, 8, stride, color,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(color);
    if (!ctx) {
        CVPixelBufferUnlockBaseAddress(bgra, 0);
        CVPixelBufferRelease(bgra);
        return NULL;
    }
    CGContextTranslateCTM(ctx, 0, height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(bgra, 0);
    return bgra;
}

/* Copy a CVPixelBuffer's BGRA surface into a CGImage. The image retains the
 * buffer's data provider; the caller keeps the pixel buffer alive until the
 * image is released. */
static CGImageRef flv_bgra_to_cgimage(CVPixelBufferRef bgra) {
    if (CVPixelBufferLockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NULL;
    uint32_t width = (uint32_t)CVPixelBufferGetWidth(bgra);
    uint32_t height = (uint32_t)CVPixelBufferGetHeight(bgra);
    size_t stride = CVPixelBufferGetBytesPerRow(bgra);
    void *base = CVPixelBufferGetBaseAddress(bgra);
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(base, width, height, 8, stride, color,
        (CGBitmapInfo)kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(color);
    if (!ctx) {
        CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
        return NULL;
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(bgra, kCVPixelBufferLock_ReadOnly);
    return image;
}

static int flv_jpeg_decode_to_nv12(const uint8_t *jpeg, size_t bytes,
                                   uint32_t expected_width, uint32_t expected_height,
                                   uint8_t **out, size_t *out_bytes,
                                   uint32_t *width_out, uint32_t *height_out) {
    if (!jpeg || !bytes || bytes > 256u * 1024u * 1024u) return FLV_LIMIT;
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, jpeg,
                                                 (CFIndex)bytes, kCFAllocatorNull);
    if (!data) return FLV_INTERNAL;
    CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
    CFRelease(data);
    if (!source) return FLV_CORRUPT;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return FLV_CORRUPT;
    uint32_t width = (uint32_t)CGImageGetWidth(image);
    uint32_t height = (uint32_t)CGImageGetHeight(image);
    int rc = flv_validate(width, height);
    if (rc == FLV_OK && expected_width && expected_height &&
        (width != expected_width || height != expected_height)) rc = FLV_INVALID;
    if (rc == FLV_OK) {
        size_t total = (size_t)width * height * 3 / 2;
        uint8_t *flat = malloc(total ? total : 1);
        if (!flat) {
            rc = FLV_INTERNAL;
        } else {
            CVPixelBufferRef bgra = flv_cgimage_to_bgra(image, width, height);
            CVPixelBufferRef nv12 = bgra ? flv_bgra_to_nv12(bgra) : NULL;
            if (bgra) CVPixelBufferRelease(bgra);
            if (!nv12) {
                rc = FLV_INTERNAL;
            } else if (CVPixelBufferLockBaseAddress(nv12, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
                rc = FLV_INTERNAL;
            } else {
                const uint8_t *ysrc = CVPixelBufferGetBaseAddressOfPlane(nv12, 0);
                const uint8_t *uvsrc = CVPixelBufferGetBaseAddressOfPlane(nv12, 1);
                size_t ystride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0);
                size_t uvstride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1);
                if (!ysrc || !uvsrc) {
                    rc = FLV_INTERNAL;
                } else {
                    uint8_t *y = flat;
                    uint8_t *uv = flat + (size_t)width * height;
                    for (uint32_t r = 0; r < height; r++) memcpy(y + (size_t)r * width, ysrc + r * ystride, width);
                    for (uint32_t r = 0; r < height / 2; r++) memcpy(uv + (size_t)r * width, uvsrc + r * uvstride, width);
                    *out = flat;
                    *out_bytes = total;
                    if (width_out) *width_out = width;
                    if (height_out) *height_out = height;
                    flat = NULL;
                }
                CVPixelBufferUnlockBaseAddress(nv12, kCVPixelBufferLock_ReadOnly);
            }
            if (nv12) CVPixelBufferRelease(nv12);
            free(flat);
        }
    }
    CGImageRelease(image);
    return rc;
}

int flv_imageio_encode_nv12(const uint8_t *y, uint32_t y_stride,
                            const uint8_t *uv, uint32_t uv_stride,
                            uint32_t width, uint32_t height,
                            uint8_t **out, size_t *out_bytes) {
    if (!y || !uv || !out || !out_bytes) return FLV_INVALID;
    int rc = flv_validate(width, height);
    if (rc != FLV_OK) return rc;
    if (y_stride < width || uv_stride < width) return FLV_INVALID;
    CVPixelBufferRef nv12 = flv_create_pixel_buffer(width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (!nv12) return FLV_INTERNAL;
    if (CVPixelBufferLockBaseAddress(nv12, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(nv12);
        return FLV_INTERNAL;
    }
    uint8_t *ydst = CVPixelBufferGetBaseAddressOfPlane(nv12, 0);
    uint8_t *uvdst = CVPixelBufferGetBaseAddressOfPlane(nv12, 1);
    size_t ydst_stride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 0);
    size_t uvdst_stride = CVPixelBufferGetBytesPerRowOfPlane(nv12, 1);
    if (!ydst || !uvdst) {
        CVPixelBufferUnlockBaseAddress(nv12, 0);
        CVPixelBufferRelease(nv12);
        return FLV_INTERNAL;
    }
    for (uint32_t r = 0; r < height; r++)
        memcpy(ydst + (size_t)r * ydst_stride, y + (size_t)r * y_stride, width);
    for (uint32_t r = 0; r < height / 2; r++)
        memcpy(uvdst + (size_t)r * uvdst_stride, uv + (size_t)r * uv_stride, width);
    CVPixelBufferUnlockBaseAddress(nv12, 0);

    CVPixelBufferRef bgra = flv_nv12_to_bgra(nv12);
    CVPixelBufferRelease(nv12);
    if (!bgra) return FLV_INTERNAL;
    CGImageRef image = flv_bgra_to_cgimage(bgra);
    if (!image) {
        CVPixelBufferRelease(bgra);
        return FLV_INTERNAL;
    }
    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef destination = data
        ? CGImageDestinationCreateWithData(data, CFSTR("public.jpeg"), 1, NULL) : NULL;
    if (!destination) {
        if (data) CFRelease(data);
        CGImageRelease(image);
        CVPixelBufferRelease(bgra);
        return FLV_INTERNAL;
    }
    NSDictionary *properties = @{
        (id)kCGImageDestinationLossyCompressionQuality: @(kFLVJPEGQuality),
        (id)kCGImagePropertyOrientation: @1,
        (id)kCGImagePropertyColorModel: (id)kCGImagePropertyColorModelRGB,
        (id)kCGImagePropertyDepth: @8,
    };
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    bool finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CVPixelBufferRelease(bgra);
    if (!finalized) {
        CFRelease(data);
        return FLV_INTERNAL;
    }
    CFIndex length = CFDataGetLength(data);
    if (length <= 0 || length > 64 * 1024 * 1024) {
        CFRelease(data);
        return FLV_LIMIT;
    }
    uint8_t *copy = malloc((size_t)length);
    if (!copy) {
        CFRelease(data);
        return FLV_INTERNAL;
    }
    memcpy(copy, CFDataGetBytePtr(data), (size_t)length);
    CFRelease(data);
    *out = copy;
    *out_bytes = (size_t)length;
    return FLV_OK;
}

int flv_imageio_decode_jpeg(const uint8_t *jpeg, size_t bytes,
                            uint32_t expected_width, uint32_t expected_height,
                            uint8_t **out, size_t *out_bytes,
                            uint32_t *width_out, uint32_t *height_out) {
    if (!out || !out_bytes) return FLV_INVALID;
    *out = NULL;
    *out_bytes = 0;
    return flv_jpeg_decode_to_nv12(jpeg, bytes, expected_width, expected_height,
                                   out, out_bytes, width_out, height_out);
}

int flv_imageio_probe(uint32_t *width_out, uint32_t *height_out) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static int cached = -1;
    static uint32_t cached_w = 0, cached_h = 0;
    pthread_mutex_lock(&lock);
    if (cached >= 0) {
        if (width_out) *width_out = cached_w;
        if (height_out) *height_out = cached_h;
        int result = cached;
        pthread_mutex_unlock(&lock);
        return result;
    }
    const uint32_t w = 640, h = 360;
    size_t frame_bytes = (size_t)w * h * 3 / 2;
    uint8_t *frame = malloc(frame_bytes);
    if (!frame) { cached = FLV_INTERNAL; pthread_mutex_unlock(&lock); return cached; }
    uint8_t *y = frame;
    uint8_t *uv = frame + (size_t)w * h;
    for (uint32_t r = 0; r < h; r++)
        for (uint32_t c = 0; c < w; c++) y[(size_t)r * w + c] = (uint8_t)((r + c) & 0xff);
    for (uint32_t r = 0; r < h / 2; r++)
        for (uint32_t c = 0; c < w; c += 2) {
            uv[(size_t)r * w + c] = 96;
            uv[(size_t)r * w + c + 1] = 160;
        }
    uint8_t *jpeg = NULL;
    size_t jpeg_bytes = 0;
    int rc = flv_imageio_encode_nv12(y, w, uv, w, w, h, &jpeg, &jpeg_bytes);
    free(frame);
    if (rc == FLV_OK && (!jpeg || jpeg_bytes < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8)) rc = FLV_INTERNAL;
    uint8_t *decoded = NULL;
    size_t decoded_bytes = 0;
    uint32_t dw = 0, dh = 0;
    if (rc == FLV_OK) {
        rc = flv_imageio_decode_jpeg(jpeg, jpeg_bytes, w, h, &decoded, &decoded_bytes, &dw, &dh);
        if (rc == FLV_OK && (!decoded || decoded_bytes != frame_bytes || dw != w || dh != h)) rc = FLV_INTERNAL;
    }
    free(jpeg);
    free(decoded);
    if (rc == FLV_OK) {
        cached = FLV_OK;
        cached_w = w;
        cached_h = h;
    } else {
        cached = rc == FLV_INTERNAL ? FLV_INTERNAL : FLV_UNSUPPORTED;
    }
    if (width_out) *width_out = cached_w;
    if (height_out) *height_out = cached_h;
    int result = cached;
    pthread_mutex_unlock(&lock);
    return result;
}
