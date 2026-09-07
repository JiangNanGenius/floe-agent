#import "FloePDFiumBridge.h"
#import <CPDFium/CPDFium.h>
#include <mutex>
#include <vector>
#include <cmath>

namespace {
std::mutex engineMutex;
std::once_flag initialized;
constexpr size_t MaxBytes = 64 * 1024 * 1024;
struct Writer : FPDF_FILEWRITE {
    NSMutableData *bytes;
    Writer() : bytes([NSMutableData data]) {
        version = 1;
        WriteBlock = [](FPDF_FILEWRITE *base, const void *data, unsigned long size) -> int {
            auto *self = static_cast<Writer *>(base);
            if (size > MaxBytes || self->bytes.length > MaxBytes - size) return 0;
            [self->bytes appendBytes:data length:size];
            return 1;
        };
    }
};
struct Document {
    FPDF_DOCUMENT value;
    ~Document() { if (value) FPDF_CloseDocument(value); }
};
struct Page {
    FPDF_PAGE value;
    ~Page() { if (value) FPDF_ClosePage(value); }
};
struct TextPage {
    FPDF_TEXTPAGE value;
    ~TextPage() { if (value) FPDFText_ClosePage(value); }
};
NSString *objectText(FPDF_PAGEOBJECT object, FPDF_TEXTPAGE textPage) {
    auto size = FPDFTextObj_GetText(object, textPage, nullptr, 0);
    if (size < 2 || size > 2 * 1024 * 1024) return nil;
    std::vector<unsigned short> buffer((size + 1) / 2);
    if (FPDFTextObj_GetText(object, textPage, buffer.data(), size) != size) return nil;
    return [[NSString alloc] initWithBytes:buffer.data() length:size - 2 encoding:NSUTF16LittleEndianStringEncoding];
}
NSDictionary *fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"org.floeagent.pdfium" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
bool onlyType(FPDF_PAGEOBJECT object, int type, int depth = 0) {
    int actual = FPDFPageObj_GetType(object);
    if (actual == type) return true;
    if (actual != FPDF_PAGEOBJ_FORM || depth >= 8) return false;
    int count = FPDFFormObj_CountObjects(object);
    if (count < 1 || count > 500) return false;
    for (int i = 0; i < count; ++i)
        if (!onlyType(FPDFFormObj_GetObject(object, i), type, depth + 1)) return false;
    return true;
}
}

@implementation FloePDFiumBridge
+ (NSData *)unlock:(NSData *)input password:(NSString *)password error:(NSError **)error {
    std::lock_guard<std::mutex> lock(engineMutex);
    std::call_once(initialized, [] { FPDF_InitLibrary(); });
    auto bad = [&](NSString *message) -> NSData * { fail(error, message); return nil; };
    if (!input.length || input.length > MaxBytes || !password.length || password.length > 200) return bad(@"PDF unlock limits exceeded");
    Document doc{FPDF_LoadMemDocument64(input.bytes, input.length, password.UTF8String)};
    if (!doc.value) return bad(@"PDF password was rejected or the document is unsupported");
    if (FPDF_GetSignatureCount(doc.value) > 0) return bad(@"Signed PDF decryption may invalidate its signatures; this tool does not alter signed files");
    if (!(FPDF_GetDocPermissions(doc.value) & (1 << 3))) return bad(@"PDF modification permissions require an owner credential");
    Writer writer;
    if (!FPDF_SaveAsCopy(doc.value, &writer, FPDF_REMOVE_SECURITY)) return bad(@"PDF decryption save failed");
    Document reopened{FPDF_LoadMemDocument64(writer.bytes.bytes, writer.bytes.length, nullptr)};
    if (!reopened.value || FPDF_GetPageCount(reopened.value) != FPDF_GetPageCount(doc.value)) return bad(@"Decrypted PDF failed reopen verification");
    return writer.bytes;
}
+ (NSData *)flatten:(NSData *)input error:(NSError **)error {
    std::lock_guard<std::mutex> lock(engineMutex);
    std::call_once(initialized, [] { FPDF_InitLibrary(); });
    auto bad = [&](NSString *message) -> NSData * { fail(error, message); return nil; };
    if (!input.length || input.length > MaxBytes) return bad(@"PDF flatten size limit");
    Document doc{FPDF_LoadMemDocument64(input.bytes, input.length, nullptr)};
    if (!doc.value || FPDF_GetSignatureCount(doc.value) > 0) return bad(@"Cannot flatten a locked, unsupported or signed PDF");
    int count = FPDF_GetPageCount(doc.value);
    if (count < 1 || count > 500) return bad(@"PDF flatten page limit");
    for (int i = 0; i < count; ++i) {
        Page page{FPDF_LoadPage(doc.value, i)};
        if (!page.value || FPDFPage_Flatten(page.value, FLAT_NORMALDISPLAY) == FLATTEN_FAIL) return bad(@"Native annotation flattening failed");
    }
    Writer writer;
    if (!FPDF_SaveAsCopy(doc.value, &writer, FPDF_NO_INCREMENTAL)) return bad(@"Flattened PDF save failed");
    return writer.bytes;
}
+ (NSData *)replaceRegion:(NSData *)input page:(NSInteger)number bounds:(NSArray<NSNumber *> *)bounds
                   overlay:(NSData *)overlay objectType:(NSInteger)objectType expectedCount:(NSInteger)expectedCount error:(NSError **)error {
    std::lock_guard<std::mutex> lock(engineMutex);
    std::call_once(initialized, [] { FPDF_InitLibrary(); });
    auto bad = [&](NSString *message) -> NSData * { fail(error, message); return nil; };
    if (!input.length || input.length > MaxBytes || overlay.length > MaxBytes || bounds.count != 4 ||
        (objectType != FPDF_PAGEOBJ_TEXT && objectType != FPDF_PAGEOBJ_IMAGE) || expectedCount < 0 || expectedCount > 500)
        return bad(@"Invalid native PDF region operation");
    Document doc{FPDF_LoadMemDocument64(input.bytes, input.length, nullptr)};
    if (!doc.value || FPDF_GetSignatureCount(doc.value) > 0) return bad(@"PDF is locked, unsupported or signed");
    if (number < 1 || number > FPDF_GetPageCount(doc.value)) return bad(@"Region page is outside the document");
    Page page{FPDF_LoadPage(doc.value, (int)number - 1)};
    if (!page.value || FPDFPage_GetRotation(page.value) != 0) return bad(@"Region operations require an unrotated readable page");
    double x = bounds[0].doubleValue, y = bounds[1].doubleValue, w = bounds[2].doubleValue, h = bounds[3].doubleValue;
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(w) || !std::isfinite(h) || x < 0 || y < 0 || w <= 0 || h <= 0 ||
        x + w > FPDF_GetPageWidthF(page.value) || y + h > FPDF_GetPageHeightF(page.value)) return bad(@"Invalid PDF region bounds");
    std::vector<FPDF_PAGEOBJECT> selected;
    int count = FPDFPage_CountObjects(page.value);
    if (count > 50000) return bad(@"PDF object limit exceeded");
    for (int i = 0; i < count; ++i) {
        auto obj = FPDFPage_GetObject(page.value, i);
        int type = FPDFPageObj_GetType(obj);
        float l, b, r, t;
        if (!FPDFPageObj_GetBounds(obj, &l, &b, &r, &t)) return bad(@"Cannot determine PDF object bounds");
        if (r <= x || l >= x+w || t <= y || b >= y+h) continue;
        if (expectedCount > 0 && type == FPDF_PAGEOBJ_FORM && !onlyType(obj, (int)objectType)) return bad(@"Mixed nested form content intersects the region; no partial removal was performed");
        if (!onlyType(obj, (int)objectType) || expectedCount == 0) continue;
        if (l < x || b < y || r > x+w || t > y+h) return bad(@"Region cuts through an existing object; enlarge the region or choose another operation");
        selected.push_back(obj);
    }
    if (selected.size() != (size_t)expectedCount) return bad(@"Region object count changed; inspect the current PDF revision");
    for (auto obj : selected) {
        if (!FPDFPage_RemoveObject(page.value, obj)) return bad(@"Native object removal failed");
        FPDFPageObj_Destroy(obj);
    }
    if (overlay.length) {
        Document addition{FPDF_LoadMemDocument64(overlay.bytes, overlay.length, nullptr)};
        if (!addition.value || FPDF_GetPageCount(addition.value) != 1) return bad(@"Region overlay must contain exactly one generated page");
        if (objectType == FPDF_PAGEOBJ_IMAGE) {
            Page sourcePage{FPDF_LoadPage(addition.value, 0)};
            FPDF_PAGEOBJECT sourceImage = nullptr;
            for (int i = 0; sourcePage.value && i < FPDFPage_CountObjects(sourcePage.value); ++i) {
                auto candidate = FPDFPage_GetObject(sourcePage.value, i);
                if (FPDFPageObj_GetType(candidate) == FPDF_PAGEOBJ_IMAGE) {
                    if (sourceImage) return bad(@"Image overlay contains multiple images");
                    sourceImage = candidate;
                }
            }
            if (!sourceImage) return bad(@"Image overlay has no native image");
            auto bitmap = FPDFImageObj_GetBitmap(sourceImage);
            auto image = FPDFPageObj_NewImageObj(doc.value);
            if (!bitmap || !image) { if (bitmap) FPDFBitmap_Destroy(bitmap); if (image) FPDFPageObj_Destroy(image); return bad(@"Cannot decode native image"); }
            bool success = FPDFImageObj_SetBitmap(nullptr, 0, image, bitmap) && FPDFImageObj_SetMatrix(image, w, 0, 0, h, x, y);
            FPDFBitmap_Destroy(bitmap);
            if (!success) { FPDFPageObj_Destroy(image); return bad(@"Native image replacement failed"); }
            FPDFPage_InsertObject(page.value, image);
        } else {
            auto xobject = FPDF_NewXObjectFromPage(doc.value, addition.value, 0);
            if (!xobject) return bad(@"Native PDF region import failed");
            auto form = FPDF_NewFormObjectFromXObject(xobject);
            FPDF_CloseXObject(xobject);
            if (!form) return bad(@"Native PDF region object creation failed");
            FPDFPageObj_Transform(form, 1, 0, 0, 1, x, y);
            FPDFPage_InsertObject(page.value, form);
        }
    }
    if (!FPDFPage_GenerateContent(page.value)) return bad(@"Native region content regeneration failed");
    Writer writer;
    if (!FPDF_SaveAsCopy(doc.value, &writer, FPDF_NO_INCREMENTAL)) return bad(@"Native region save failed");
    return writer.bytes;
}
+ (NSData *)inspect:(NSData *)input error:(NSError **)error {
    return [self inspect:input pages:nil error:error];
}
+ (NSData *)inspect:(NSData *)input pages:(NSArray<NSNumber *> *)selection error:(NSError **)error {
    std::lock_guard<std::mutex> lock(engineMutex);
    std::call_once(initialized, [] { FPDF_InitLibrary(); });
    if (!input.length || input.length > MaxBytes) { fail(error, @"PDF exceeds the inspection size limit"); return nil; }
    Document doc{FPDF_LoadMemDocument64(input.bytes, input.length, nullptr)};
    if (!doc.value) { fail(error, @"Native PDF inspection could not open this file"); return nil; }
    int pageCount = FPDF_GetPageCount(doc.value);
    if (pageCount < 1 || pageCount > 1000) { fail(error, @"PDF page count exceeds the inspection limit"); return nil; }
    if (selection.count > 20) { fail(error, @"Select at most 20 PDF pages for inventory"); return nil; }
    for (NSNumber *number in selection) {
        if (number.integerValue < 1 || number.integerValue > pageCount) { fail(error, @"Inventory page outside document"); return nil; }
    }
    NSMutableArray *pages = [NSMutableArray array];
    bool imageOnly = true;
    for (int i = 0; i < pageCount; ++i) {
        Page page{FPDF_LoadPage(doc.value, i)};
        if (!page.value) { fail(error, @"Cannot inspect PDF page"); return nil; }
        int count = FPDFPage_CountObjects(page.value);
        if (count > 50000) { fail(error, @"PDF page object limit"); return nil; }
        NSMutableArray *objects = [NSMutableArray array];
        bool selected = selection ? [selection containsObject:@(i+1)] : i < 20;
        for (int j = 0; j < count; ++j) {
            auto object = FPDFPage_GetObject(page.value, j);
            int type = FPDFPageObj_GetType(object);
            imageOnly = imageOnly && type == FPDF_PAGEOBJ_IMAGE;
            float l, b, r, t;
            if (selected && j < 100 && FPDFPageObj_GetBounds(object, &l, &b, &r, &t))
                [objects addObject:@{@"index":@(j), @"type":@(type), @"contentType":onlyType(object, FPDF_PAGEOBJ_TEXT) ? @"text" : onlyType(object, FPDF_PAGEOBJ_IMAGE) ? @"image" : @"mixedOrOther", @"bounds":@[@(l),@(b),@(r-l),@(t-b)]}];
        }
        if (selected) [pages addObject:@{@"page":@(i+1), @"objectCount":@(count), @"objectsTruncated":@(count > 100), @"objects":objects}];
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"pages":pages, @"pageCount":@(pageCount),
        @"signatureCount":@(FPDF_GetSignatureCount(doc.value)), @"attachmentCount":@(FPDFDoc_GetAttachmentCount(doc.value)),
        @"imageObjectsOnly":@(imageOnly)} options:0 error:error];
}
+ (NSDictionary<NSString *,id> *)rewrite:(NSData *)input operationsJSON:(NSData *)operations cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    std::lock_guard<std::mutex> lock(engineMutex);
    std::call_once(initialized, [] { FPDF_InitLibrary(); });
    if (!input.length || input.length > MaxBytes || operations.length > 128 * 1024)
        return fail(error, @"PDF edit exceeds the native memory limit");
    id decoded = [NSJSONSerialization JSONObjectWithData:operations options:0 error:error];
    if (![decoded isKindOfClass:NSArray.class] || [decoded count] > 20)
        return fail(error, @"Invalid PDF replacement operations");
    NSArray *rules = decoded;
    Document doc{FPDF_LoadMemDocument64(input.bytes, input.length, nullptr)};
    if (!doc.value) return fail(error, @"PDFium could not open this PDF (locked or unsupported file)");
    if (FPDF_GetSignatureCount(doc.value) > 0)
        return fail(error, @"This PDF contains a digital signature. Editing may invalidate it; create an explicitly authorized unsigned copy first");
    int pageCount = FPDF_GetPageCount(doc.value);
    if (pageCount <= 0 || pageCount > 1000) return fail(error, @"PDF page count exceeds the editing limit");
    NSUInteger replaced = 0;
    for (NSDictionary *rule in rules) {
        if (cancelled()) return fail(error, @"PDF editing cancelled before save");
        if (![rule isKindOfClass:NSDictionary.class]) return fail(error, @"Invalid replacement rule");
        NSString *find = rule[@"find"], *replacement = rule[@"replace"];
        NSArray *pages = rule[@"pages"];
        if (![find isKindOfClass:NSString.class] || !find.length || find.length > 500 || ![replacement isKindOfClass:NSString.class] || replacement.length > 500)
            return fail(error, @"Invalid PDF replacement text");
        if (pages && ![pages isKindOfClass:NSArray.class]) return fail(error, @"Invalid PDF page selection");
        for (id number in pages) {
            if (![number isKindOfClass:NSNumber.class] || [number intValue] < 1 || [number intValue] > pageCount)
                return fail(error, @"PDF replacement page does not exist");
        }
        NSUInteger ruleMatches = 0;
        for (int index = 0; index < pageCount; ++index) {
            if (cancelled()) return fail(error, @"PDF editing cancelled before save");
            if (pages && ![pages containsObject:@(index + 1)]) continue;
            Page page{FPDF_LoadPage(doc.value, index)};
            if (!page.value) return fail(error, @"PDF page could not be opened");
            TextPage text{FPDFText_LoadPage(page.value)};
            if (!text.value) return fail(error, @"PDF page text could not be inspected");
            bool changed = false;
            int objects = FPDFPage_CountObjects(page.value);
            if (objects > 50000) return fail(error, @"PDF page contains too many objects");
            for (int i = 0; i < objects; ++i) {
                if (cancelled()) return fail(error, @"PDF editing cancelled before save");
                auto object = FPDFPage_GetObject(page.value, i);
                if (FPDFPageObj_GetType(object) != FPDF_PAGEOBJ_TEXT) continue;
                NSString *original = objectText(object, text.value);
                if (!original || [original rangeOfString:find].location == NSNotFound) continue;
                NSUInteger count = [original componentsSeparatedByString:find].count - 1;
                if (replaced + count > 200) return fail(error, @"Too many replacements; select fewer pages");
                NSString *updated = [original stringByReplacingOccurrencesOfString:find withString:replacement];
                std::vector<unsigned short> wide(updated.length + 1, 0);
                [updated getCharacters:wide.data() range:NSMakeRange(0, updated.length)];
                float l, b, r, t, nl, nb, nr, nt;
                if (!FPDFPageObj_GetBounds(object, &l, &b, &r, &t) || !FPDFText_SetText(object, wide.data()))
                    return fail(error, @"The original PDF font cannot encode this replacement");
                if (updated.length && (!FPDFPageObj_GetBounds(object, &nl, &nb, &nr, &nt) || nr > r + 1 || nt > t + 1 || nl < l - 1 || nb < b - 1))
                    return fail(error, @"Replacement overflows the original text region; no output was saved");
                TextPage updatedText{FPDFText_LoadPage(page.value)};
                if (!updatedText.value || ![objectText(object, updatedText.value) isEqualToString:updated])
                    return fail(error, @"Replacement text failed font/Unicode verification; no output was saved");
                ruleMatches += count; replaced += count; changed = true;
            }
            if (changed && !FPDFPage_GenerateContent(page.value)) return fail(error, @"PDF content stream regeneration failed");
        }
        if (!ruleMatches) return fail(error, @"No editable text-object match. Scanned, nested or cross-object text needs the corresponding editing workflow; no visual cover was applied");
    }
    Writer writer;
    if (!FPDF_SaveAsCopy(doc.value, &writer, FPDF_NO_INCREMENTAL)) return fail(error, @"PDF content-stream save failed");
    Document reopened{FPDF_LoadMemDocument64(writer.bytes.bytes, writer.bytes.length, nullptr)};
    if (!reopened.value || FPDF_GetPageCount(reopened.value) != pageCount) return fail(error, @"Reopening edited PDF failed");
    return @{@"data": writer.bytes, @"replacements": @(replaced)};
}
@end
