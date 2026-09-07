#import "FloePDFiumBridge.h"
#import <CPDFium/CPDFium.h>
#include <mutex>
#include <vector>

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
}

@implementation FloePDFiumBridge
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
