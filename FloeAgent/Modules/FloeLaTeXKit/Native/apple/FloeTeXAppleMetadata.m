// SPDX-License-Identifier: MPL-2.0
#import "FloeTeXAppleMetadata.h"
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <pthread.h>

static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static FloeTeXApplePDFGate app_pdf_gate = NULL;

int32_t floe_tex_apple_set_pdf_gate(FloeTeXApplePDFGate gate) {
    if (!gate) return -1;
    pthread_mutex_lock(&gate_lock);
    int32_t result = app_pdf_gate && app_pdf_gate != gate ? -2 : 0;
    if (!result) app_pdf_gate = gate;
    pthread_mutex_unlock(&gate_lock);
    return result;
}

static int32_t page_index(int32_t requested, size_t count) {
    int64_t value = requested == 0 ? 1 : requested;
    if (value < 0) value = (int64_t)count + value + 1;
    return value > 0 && value <= (int64_t)count ? (int32_t)value : 0;
}
static int valid_rect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) && isfinite(r.size.width)
        && isfinite(r.size.height) && r.size.width > 0 && r.size.height > 0
        && fabs(r.origin.x) <= 1000000 && fabs(r.origin.y) <= 1000000
        && r.size.width <= 100000 && r.size.height <= 100000;
}
typedef struct {
    CFDataRef data;
    int32_t requested;
    int32_t box;
    double *rect;
    int32_t *count;
} PDFMetadata;

static int32_t pdf_metadata(void *opaque) {
    PDFMetadata *input = opaque;
    @try {
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(input->data);
        if (!provider) return -3;
        CGPDFDocumentRef document = CGPDFDocumentCreateWithProvider(provider);
        CGDataProviderRelease(provider);
        if (!document) return -3;
        int32_t result = 0;
        size_t count = CGPDFDocumentGetNumberOfPages(document);
        int32_t index = page_index(input->requested, count);
        if (CGPDFDocumentIsEncrypted(document) && !CGPDFDocumentIsUnlocked(document)) result = -4;
        else if (count == 0 || count > 10000 || !index) result = -5;
        else {
            CGPDFPageRef page = CGPDFDocumentGetPage(document, index);
            CGPDFBox box = kCGPDFCropBox;
            switch (input->box) {
                case 1: box = kCGPDFCropBox; break;
                case 2: box = kCGPDFMediaBox; break;
                case 3: box = kCGPDFBleedBox; break;
                case 4: box = kCGPDFTrimBox; break;
                case 5: box = kCGPDFArtBox; break;
                default: result = -1;
            }
            if (!result) {
                CGRect r = page ? CGPDFPageGetBoxRect(page, box) : CGRectNull;
                int rotation = page ? CGPDFPageGetRotationAngle(page) % 360 : 0;
                if (rotation % 90 != 0) result = -6;
                if (rotation) r = CGRectApplyAffineTransform(r, CGAffineTransformMakeRotation(-rotation*M_PI/180.0));
                if (!valid_rect(r)) result = -6;
                else if (!result) {
                    input->rect[0] = r.origin.x; input->rect[1] = r.origin.y;
                    input->rect[2] = r.size.width; input->rect[3] = r.size.height;
                    *input->count = (int32_t)count;
                }
            }
        }
        CGPDFDocumentRelease(document);
        return result;
    } @catch (__unused NSException *exception) { return -8; }
}

static double number(CFDictionaryRef values, CFStringRef key, double fallback) {
    CFTypeRef value = CFDictionaryGetValue(values, key);
    double result = 0;
    return value && CFGetTypeID(value) == CFNumberGetTypeID()
        && CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &result)
        && isfinite(result) && result > 0 ? result : fallback;
}

int32_t floe_tex_image_metadata(const uint8_t *bytes, size_t length,
        int32_t requested_page, int32_t box, double rect_bp[4], int32_t *page_count) {
    if (!bytes || !length || length > 64 * 1024 * 1024 || !rect_bp || !page_count || box < 0 || box > 5) return -1;
    for (int i=0; i<4; ++i) rect_bp[i] = 0;
    *page_count = 0;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)length);
    if (!data) return -1;
    int32_t result = -2;
    @try {
        if (box != 0) {
            pthread_mutex_lock(&gate_lock);
            FloeTeXApplePDFGate gate = app_pdf_gate;
            pthread_mutex_unlock(&gate_lock);
            if (!gate) result = -7;
            else {
                PDFMetadata input = { data, requested_page, box, rect_bp, page_count };
                result = gate(pdf_metadata, &input);
            }
        } else {
            CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
            if (source) {
                size_t count = CGImageSourceGetCount(source);
                int32_t index = page_index(requested_page, count);
                if (count > 10000 || !index) result = -5;
                else {
                    CFDictionaryRef values = CGImageSourceCopyPropertiesAtIndex(source, (size_t)index-1, NULL);
                    if (values) {
                        double width = number(values, kCGImagePropertyPixelWidth, 0);
                        double height = number(values, kCGImagePropertyPixelHeight, 0);
                        double dpi_x = number(values, kCGImagePropertyDPIWidth, 72);
                        double dpi_y = number(values, kCGImagePropertyDPIHeight, 72);
                        double orientation = number(values, kCGImagePropertyOrientation, 1);
                        double w = width * 72 / dpi_x, h = height * 72 / dpi_y;
                        if (orientation >= 5 && orientation <= 8) { double tmp=w; w=h; h=tmp; }
                        CGRect r = CGRectMake(0, 0, w, h);
                        if (width > 32768 || height > 32768 || width*height > 16777216 || !valid_rect(r)) result = -6;
                        else { rect_bp[2]=w; rect_bp[3]=h; *page_count=(int32_t)count; result=0; }
                        CFRelease(values);
                    }
                }
                CFRelease(source);
            }
        }
    } @catch (__unused NSException *exception) { result = -8; }
    CFRelease(data);
    return result;
}
