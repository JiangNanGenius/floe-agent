// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
// Compound storage is written by the pinned LibreOffice SotStorage engine.
// Ole10Native package field layout follows MS-OLEDS and Apache POI's public
// Ole10Native format documentation; no external path is embedded in the file.
#include <sot/storage.hxx>
#include <sot/exchange.hxx>
#include <tools/globname.hxx>
#include <tools/stream.hxx>
#include <vcl/svapp.hxx>
#include <sfx2/viewsh.hxx>
#include <sfx2/objsh.hxx>
#include <oox/ole/oleobjecthelper.hxx>
#include <comphelper/propertyvalue.hxx>
#include <comphelper/processfactory.hxx>
#include <com/sun/star/document/XEmbeddedObjectResolver.hpp>
#include <com/sun/star/container/XNameAccess.hpp>
#include <com/sun/star/lang/XMultiServiceFactory.hpp>
#include <com/sun/star/text/XTextDocument.hpp>
#include <com/sun/star/text/XTextViewCursorSupplier.hpp>
#include <com/sun/star/text/XTextContent.hpp>
#include <com/sun/star/text/TextContentAnchorType.hpp>
#include <com/sun/star/beans/XPropertySet.hpp>
#include <com/sun/star/graphic/GraphicProvider.hpp>
#include <com/sun/star/io/XOutputStream.hpp>
#include <array>
#include <limits>

static OUString FloeUNOString(NSString *text) {
    return OUString::fromUtf8(OString(text.UTF8String));
}

static void FloeWriteAttachmentPackage(NSURL *sourceURL, NSURL *packageURL, NSString *displayName) {
    SvFileStream source(FloeUNOString(sourceURL.absoluteString), StreamMode::READ);
    const sal_uInt64 size = source.TellEnd();
    if (source.GetError() || size > std::numeric_limits<sal_uInt32>::max() - 65536)
        throw std::runtime_error("Attachment could not be read or exceeds the OLE package size.");
    rtl::Reference<SotStorage> storage = new SotStorage(false, FloeUNOString(packageURL.absoluteString),
                                                       StreamMode::STD_READWRITE | StreamMode::TRUNC);
    storage->SetClass(SvGlobalName(0x0003000c, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46),
                      SotClipboardFormatId::NONE, u"Package"_ustr);
    auto native = storage->OpenSotStream(u"\001Ole10Native"_ustr);
    const OString name(displayName.UTF8String);
    const OUString unicodeName = FloeUNOString(displayName);
    native->WriteUInt32(0); // Backfilled after streaming; excludes this DWORD.
    native->WriteUInt16(2);
    native->WriteBytes(name.getStr(), name.getLength()); native->WriteUChar(0);
    native->WriteBytes(name.getStr(), name.getLength()); native->WriteUChar(0);
    native->WriteUInt16(0); native->WriteUInt16(3);
    native->WriteUInt32(name.getLength() + 1);
    native->WriteBytes(name.getStr(), name.getLength()); native->WriteUChar(0);
    native->WriteUInt32(static_cast<sal_uInt32>(size));
    std::array<char, 65536> buffer;
    source.Seek(0);
    sal_uInt64 remaining = size;
    while (remaining) {
        const auto requested = static_cast<std::size_t>(std::min<sal_uInt64>(remaining, buffer.size()));
        const auto count = source.ReadBytes(buffer.data(), requested);
        if (count != requested) throw std::runtime_error("Attachment changed while packaging.");
        native->WriteBytes(buffer.data(), count);
        remaining -= count;
    }
    // Package Unicode extension: command, label, filename. Preserve Chinese
    // and non-BMP names independently of the legacy UTF-8 fields.
    for (int field = 0; field < 3; ++field) {
        native->WriteUInt32(unicodeName.getLength());
        for (sal_Int32 i = 0; i < unicodeName.getLength(); ++i) native->WriteUInt16(unicodeName[i]);
    }
    const auto end = native->Tell();
    native->Seek(0); native->WriteUInt32(static_cast<sal_uInt32>(end - 4));
    native->Commit();
    auto ole = storage->OpenSotStream(u"\001Ole"_ustr);
    ole->WriteUInt32(0x02000001); ole->WriteUInt32(0); ole->WriteUInt32(0);
    ole->WriteUInt32(0); ole->WriteUInt32(0); ole->Commit();
    if (source.GetError() || native->GetError() || ole->GetError() || !storage->Commit() || storage->GetError())
        throw std::runtime_error("Attachment package could not be persisted.");
}

// Must run under SolarMutex with the selected document view active. Use the
// existing engine import resolver and Writer object insertion/undo machinery;
// never rewrite the DOCX archive behind an open editor.
static void FloeInsertWordAttachment(COKitDocument *document, NSURL *packageURL,
                                     NSURL *iconURL, NSString *displayName) {
    namespace css = com::sun::star;
    SolarMutexGuard guard;
    std::vector<int> views;
    if (!document || document->getDocumentType() != COKitDocumentType::TEXT ||
        !document->getViewIds(views) || views.size() != 1)
        throw std::runtime_error("A single active Word view is required for attachment insertion.");
    document->setView(views.front());
    SfxViewShell *shell = SfxViewShell::Current();
    if (!shell || !shell->GetObjectShell()) throw std::runtime_error("The Word view is unavailable.");
    auto model = shell->GetObjectShell()->GetModel();
    css::uno::Reference<css::text::XTextDocument> textDocument(model, css::uno::UNO_QUERY_THROW);
    css::uno::Reference<css::lang::XMultiServiceFactory> factory(model, css::uno::UNO_QUERY_THROW);
    css::uno::Reference<css::text::XTextViewCursorSupplier> supplier(model->getCurrentController(), css::uno::UNO_QUERY_THROW);
    auto cursor = supplier->getViewCursor();
    css::uno::Reference<css::document::XEmbeddedObjectResolver> resolver(
        factory->createInstance(u"com.sun.star.document.ImportEmbeddedObjectResolver"_ustr), css::uno::UNO_QUERY_THROW);
    css::uno::Reference<css::lang::XComponent> resolverLifetime(resolver, css::uno::UNO_QUERY_THROW);
    try {
        const OUString objectID = u"FloeAttachment"_ustr + FloeUNOString(NSUUID.UUID.UUIDString);
        css::uno::Reference<css::container::XNameAccess> names(resolver, css::uno::UNO_QUERY_THROW);
        css::uno::Reference<css::io::XOutputStream> output(names->getByName(objectID), css::uno::UNO_QUERY_THROW);
        SvFileStream input(FloeUNOString(packageURL.absoluteString), StreamMode::READ);
        sal_uInt64 remaining = input.TellEnd(); input.Seek(0);
        while (remaining) {
            cpo::uno::Sequence<sal_Int8> bytes(static_cast<sal_Int32>(std::min<sal_uInt64>(remaining, 65536)));
            const auto count = input.ReadBytes(bytes.getArray(), bytes.getLength());
            if (count != static_cast<std::size_t>(bytes.getLength())) throw std::runtime_error("Attachment package read failed.");
            output->writeBytes(bytes); remaining -= count;
        }
        output->closeOutput();
        const OUString resolved = resolver->resolveEmbeddedObjectURL(objectID);
        const OUString prefix = u"vnd.sun.star.EmbeddedObject:"_ustr;
        if (!resolved.startsWith(prefix) || resolved.getLength() == prefix.getLength())
            throw std::runtime_error("Attachment was not stored in the document.");
        const OUString streamName = resolved.copy(prefix.getLength());
        auto object = factory->createInstance(u"com.sun.star.text.TextEmbeddedObject"_ustr);
        css::uno::Reference<css::beans::XPropertySet> properties(object, css::uno::UNO_QUERY_THROW);
        properties->setPropertyValue(u"StreamName"_ustr, cpo::uno::Any(streamName));
        properties->setPropertyValue(u"DrawAspect"_ustr, cpo::uno::Any(u"Icon"_ustr));
        properties->setPropertyValue(u"AnchorType"_ustr, cpo::uno::Any(css::text::TextContentAnchorType_AS_CHARACTER));
        properties->setPropertyValue(u"Width"_ustr, cpo::uno::Any(sal_Int32(6000)));
        properties->setPropertyValue(u"Height"_ustr, cpo::uno::Any(sal_Int32(1800)));
        properties->setPropertyValue(u"Title"_ustr, cpo::uno::Any(FloeUNOString(displayName)));
        auto graphics = css::graphic::GraphicProvider::create(comphelper::getProcessComponentContext());
        auto graphic = graphics->queryGraphic({comphelper::makePropertyValue(u"URL"_ustr, FloeUNOString(iconURL.absoluteString))});
        properties->setPropertyValue(u"Graphic"_ustr, cpo::uno::Any(graphic));
        oox::ole::SaveInteropProperties(model, streamName, nullptr, u"Package"_ustr);
        css::uno::Reference<css::text::XTextContent> content(object, css::uno::UNO_QUERY_THROW);
        cursor->getText()->insertTextContent(cursor, content, false);
        resolverLifetime->dispose();
    } catch (...) {
        try { resolverLifetime->dispose(); } catch (...) { /* Preserve insertion error. */ }
        throw;
    }
}
