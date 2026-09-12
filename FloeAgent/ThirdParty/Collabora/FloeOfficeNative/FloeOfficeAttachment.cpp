// Copyright Floe contributors. SPDX-License-Identifier: MPL-2.0
// Compound storage is written by the pinned LibreOffice SotStorage engine.
// Ole10Native package field layout follows MS-OLEDS and Apache POI's public
// Ole10Native format documentation; no external path is embedded in the file.
#include "config.h"
#define LIBO_INTERNAL_ONLY
#include "FloeOfficeAttachment.hxx"
#include <COKit/COKit.hxx>
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
#include <comphelper/embeddedobjectcontainer.hxx>
#include <svl/undo.hxx>
#include <svx/svdobj.hxx>
#include <svx/svdpage.hxx>
#include <svx/svdundo.hxx>
#include <cppuhelper/weakref.hxx>
#include <com/sun/star/document/XEmbeddedObjectResolver.hpp>
#include <com/sun/star/embed/XEmbeddedObject.hpp>
#include <com/sun/star/container/XNameAccess.hpp>
#include <com/sun/star/lang/XMultiServiceFactory.hpp>
#include <com/sun/star/text/XTextDocument.hpp>
#include <com/sun/star/text/XTextEmbeddedObjectsSupplier.hpp>
#include <com/sun/star/embed/XStorage.hpp>
#include <com/sun/star/embed/ElementModes.hpp>
#include <com/sun/star/io/XStream.hpp>
#include <unotools/ucbstreamhelper.hxx>
#include <com/sun/star/text/XTextViewCursorSupplier.hpp>
#include <com/sun/star/text/XTextContent.hpp>
#include <com/sun/star/text/TextContentAnchorType.hpp>
#include <com/sun/star/beans/XPropertySet.hpp>
#include <com/sun/star/graphic/GraphicProvider.hpp>
#include <com/sun/star/io/XOutputStream.hpp>
#include <com/sun/star/drawing/XDrawView.hpp>
#include <com/sun/star/drawing/XDrawPageSupplier.hpp>
#include <com/sun/star/drawing/XDrawPagesSupplier.hpp>
#include <com/sun/star/drawing/XShapes.hpp>
#include <com/sun/star/sheet/XSpreadsheetView.hpp>
#include <com/sun/star/sheet/XCellRangeAddressable.hpp>
#include <com/sun/star/view/XSelectionSupplier.hpp>
#include <com/sun/star/embed/Aspects.hpp>
#include <array>
#include <algorithm>
#include <limits>
#include <stdexcept>

static OUString FloeUNOString(const std::string &text) {
    return OUString::fromUtf8(text);
}

static void FloeWriteAttachmentPackage(const std::string &sourceURL, const std::string &packageURL, const std::string &displayName) {
    SvFileStream source(FloeUNOString(sourceURL), StreamMode::READ);
    const sal_uInt64 size = source.TellEnd();
    if (source.GetError() || size > std::numeric_limits<sal_uInt32>::max() - 65536)
        throw std::runtime_error("Attachment could not be read or exceeds the OLE package size.");
    rtl::Reference<SotStorage> storage = new SotStorage(false, FloeUNOString(packageURL),
                                                       StreamMode::STD_READWRITE | StreamMode::TRUNC);
    storage->SetClass(SvGlobalName(0x0003000c, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46),
                      SotClipboardFormatId::NONE, u"Package"_ustr);
    auto native = storage->OpenSotStream(u"\001Ole10Native"_ustr);
    // Legacy Package names are ANSI. Give old readers an unambiguous ASCII
    // fallback; the Unicode extension below retains the full original name.
    std::string legacyName = displayName;
    if (std::any_of(legacyName.begin(), legacyName.end(), [](unsigned char c) { return c >= 128; })) {
        const auto dot = displayName.find_last_of('.');
        const std::string extension = dot == std::string::npos ? "" : displayName.substr(dot);
        legacyName = "Attachment";
        if (std::all_of(extension.begin(), extension.end(), [](unsigned char c) { return c < 128; }))
            legacyName += extension;
    }
    const OString name(legacyName.c_str());
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

// Writer renames objects when restoring their temporary undo storage, while
// its DOCX exporter looks up ProgID by the current storage name. Keep that
// metadata attached to this object after redo. Weak references avoid retaining
// a closed document through its own undo stack.
class FloeAttachmentInteropUndo final : public SfxUndoAction {
    cpo::uno::WeakReferenceHelper model;
    cpo::uno::WeakReferenceHelper object;
    ViewShellId viewID;
public:
    FloeAttachmentInteropUndo(const css::uno::Reference<css::frame::XModel> &owner,
                              const css::uno::Reference<css::embed::XEmbeddedObject> &attachment, ViewShellId view)
        : model(owner), object(attachment), viewID(view) {}
    OUString GetComment() const override { return u"Insert attachment"_ustr; }
    ViewShellId GetViewShellId() const override { return viewID; }
    void Undo() override {} // The grouped Writer action removes the object.
    void Redo() override {
        SolarMutexGuard guard;
        css::uno::Reference<css::frame::XModel> owner(model.get(), css::uno::UNO_QUERY);
        css::uno::Reference<css::embed::XEmbeddedObject> attachment(object.get(), css::uno::UNO_QUERY);
        if (!owner || !attachment) return;
        SfxObjectShell *shell = SfxObjectShell::GetShellFromComponent(owner);
        if (!shell) return;
        const OUString name = shell->GetEmbeddedObjectContainer().GetEmbeddedObjectName(attachment);
        if (!name.isEmpty()) oox::ole::SaveInteropProperties(owner, name, nullptr, u"Package"_ustr);
    }
};

// Calc/Impress can move the object into a differently named storage during
// undo/redo. Restore the Package metadata after the native action has restored
// the object, looking up its current PersistName rather than the original name.
// SdrUndoNewObj owns the same object throughout the native undo lifecycle;
// the document reference remains weak to avoid a document/undo-stack cycle.
class FloeDrawingAttachmentUndo final : public SdrUndoNewObj {
    cpo::uno::WeakReferenceHelper model;
public:
    FloeDrawingAttachmentUndo(SdrObject &object, const css::uno::Reference<css::frame::XModel> &owner)
        : SdrUndoNewObj(object), model(owner) {}
    void Redo() override {
        SolarMutexGuard guard;
        SdrUndoNewObj::Redo();
        css::uno::Reference<css::frame::XModel> owner(model.get(), css::uno::UNO_QUERY);
        if (!owner || !mxObj || !mxObj->IsInserted()) return;
        css::uno::Reference<css::beans::XPropertySet> properties(mxObj->getUnoShape(), css::uno::UNO_QUERY_THROW);
        OUString currentName;
        properties->getPropertyValue(u"PersistName"_ustr) >>= currentName;
        if (currentName.isEmpty()) throw std::runtime_error("Restored attachment storage is unavailable.");
        oox::ole::SaveInteropProperties(owner, currentName, nullptr, u"Package"_ustr);
    }
};

// Must run under SolarMutex with the selected document view active. Use the
// existing engine import resolver and Writer object insertion/undo machinery;
// never rewrite the DOCX archive behind an open editor.
static void FloeInsertWordAttachment(COKitDocument *document, const std::string &packageURL,
                                     const std::string &iconURL, const std::string &displayName,
                                     const std::string &identifier) {
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
    // UNO enterUndoContext creates an unowned (-1) list action, which the
    // collaborative engine refuses to undo from this editor. Use the document's
    // native manager and explicitly tag both group and metadata with this view.
    SfxUndoManager *undo = shell->GetObjectShell()->GetUndoManager();
    if (!undo || !undo->IsUndoEnabled()) throw std::runtime_error("Document undo is unavailable.");
    const ViewShellId viewID = shell->GetViewShellId();
    undo->EnterListAction(u"Insert attachment"_ustr, u"Insert attachment"_ustr, 0, viewID);
    bool undoContextOpen = true;
    try {
        const OUString objectID = u"FloeAttachment"_ustr + FloeUNOString(identifier);
        css::uno::Reference<css::container::XNameAccess> names(resolver, css::uno::UNO_QUERY_THROW);
        css::uno::Reference<css::io::XOutputStream> output(names->getByName(objectID), css::uno::UNO_QUERY_THROW);
        SvFileStream input(FloeUNOString(packageURL), StreamMode::READ);
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
        auto graphic = graphics->queryGraphic({comphelper::makePropertyValue(u"URL"_ustr, FloeUNOString(iconURL))});
        properties->setPropertyValue(u"Graphic"_ustr, cpo::uno::Any(graphic));
        css::uno::Reference<css::text::XTextContent> content(object, css::uno::UNO_QUERY_THROW);
        cursor->getText()->insertTextContent(cursor, content, false);
        css::uno::Reference<css::embed::XEmbeddedObject> embedded(
            properties->getPropertyValue(u"EmbeddedObject"_ustr), css::uno::UNO_QUERY_THROW);
        auto metadata = std::make_unique<FloeAttachmentInteropUndo>(model, embedded, viewID);
        metadata->Redo();
        undo->AddUndoAction(std::move(metadata));
        undoContextOpen = false;
        undo->LeaveListAction();
        try { resolverLifetime->dispose(); } catch (...) { /* Insertion already succeeded. */ }
    } catch (...) {
        if (undoContextOpen) { try { undo->LeaveListAction(); } catch (...) {} }
        try { resolverLifetime->dispose(); } catch (...) { /* Preserve insertion error. */ }
        throw;
    }
}

// Calc and Impress own attachments as drawing objects. Insert into the active
// sheet/slide, using the engine object and undo stack rather than editing ZIP
// parts behind the live document. Calc positions the icon at the selected cell;
// Impress centres it on the active slide, where the normal handles can move it.
static void FloeInsertDrawingAttachment(COKitDocument *document, const std::string &packageURL,
                                        const std::string &iconURL, const std::string &displayName,
                                        const std::string &identifier) {
    SolarMutexGuard guard;
    std::vector<int> views;
    if (!document || !document->getViewIds(views) || views.size() != 1)
        throw std::runtime_error("A single active Office view is required for attachment insertion.");
    document->setView(views.front());
    auto shell = SfxViewShell::Current();
    if (!shell || !shell->GetObjectShell()) throw std::runtime_error("The Office view is unavailable.");
    auto owner = shell->GetObjectShell();
    auto model = owner->GetModel();
    auto controller = model->getCurrentController();
    css::uno::Reference<css::drawing::XDrawPage> page;
    css::awt::Point position;
    css::awt::Size size(6000, 1800);
    if (document->getDocumentType() == COKitDocumentType::SPREADSHEET) {
        css::uno::Reference<css::sheet::XSpreadsheetView> view(controller, css::uno::UNO_QUERY_THROW);
        auto sheet = view->getActiveSheet();
        css::uno::Reference<css::drawing::XDrawPageSupplier> supplier(sheet, css::uno::UNO_QUERY_THROW);
        page = supplier->getDrawPage();
        css::uno::Reference<css::view::XSelectionSupplier> selection(controller, css::uno::UNO_QUERY_THROW);
        css::uno::Reference<css::sheet::XCellRangeAddressable> range(selection->getSelection(), css::uno::UNO_QUERY_THROW);
        const auto address = range->getRangeAddress();
        css::uno::Reference<css::beans::XPropertySet> cell(
            sheet->getCellByPosition(address.StartColumn, address.StartRow), css::uno::UNO_QUERY_THROW);
        if (!(cell->getPropertyValue(u"Position"_ustr) >>= position))
            throw std::runtime_error("Select the cell where the attachment should be inserted.");
    } else if (document->getDocumentType() == COKitDocumentType::PRESENTATION) {
        css::uno::Reference<css::drawing::XDrawView> view(controller, css::uno::UNO_QUERY_THROW);
        page = view->getCurrentPage();
        css::uno::Reference<css::beans::XPropertySet> properties(page, css::uno::UNO_QUERY_THROW);
        sal_Int32 width = 0, height = 0;
        if (!(properties->getPropertyValue(u"Width"_ustr) >>= width) ||
            !(properties->getPropertyValue(u"Height"_ustr) >>= height) || width <= 0 || height <= 0)
            throw std::runtime_error("The active slide dimensions are unavailable.");
        size.Width = std::min(size.Width, width);
        size.Height = std::min(size.Height, height);
        position = css::awt::Point((width - size.Width) / 2, (height - size.Height) / 2);
    } else {
        throw std::runtime_error("This document does not support embedded attachments.");
    }
    if (!page) throw std::runtime_error("The active sheet or slide is unavailable.");
    auto undo = owner->GetUndoManager();
    if (!undo || !undo->IsUndoEnabled()) throw std::runtime_error("Document undo is unavailable.");
    css::uno::Reference<css::lang::XMultiServiceFactory> factory(model, css::uno::UNO_QUERY_THROW);
    auto graphics = css::graphic::GraphicProvider::create(comphelper::getProcessComponentContext());
    auto graphic = graphics->queryGraphic({comphelper::makePropertyValue(u"URL"_ustr, FloeUNOString(iconURL))});
    if (!graphic) throw std::runtime_error("The attachment preview could not be read.");
    css::uno::Reference<css::document::XEmbeddedObjectResolver> resolver(
        factory->createInstance(u"com.sun.star.document.ImportEmbeddedObjectResolver"_ustr), css::uno::UNO_QUERY_THROW);
    css::uno::Reference<css::lang::XComponent> lifetime(resolver, css::uno::UNO_QUERY_THROW);
    css::uno::Reference<css::drawing::XShape> shape;
    OUString streamName;
    bool committed = false;
    try {
        const OUString objectID = u"FloeAttachment"_ustr + FloeUNOString(identifier);
        css::uno::Reference<css::container::XNameAccess> names(resolver, css::uno::UNO_QUERY_THROW);
        css::uno::Reference<css::io::XOutputStream> output(names->getByName(objectID), css::uno::UNO_QUERY_THROW);
        SvFileStream input(FloeUNOString(packageURL), StreamMode::READ);
        sal_uInt64 remaining = input.TellEnd(); input.Seek(0);
        while (remaining) {
            cpo::uno::Sequence<sal_Int8> bytes(static_cast<sal_Int32>(std::min<sal_uInt64>(remaining, 65536)));
            if (input.ReadBytes(bytes.getArray(), bytes.getLength()) != static_cast<std::size_t>(bytes.getLength()))
                throw std::runtime_error("Attachment package read failed.");
            output->writeBytes(bytes); remaining -= bytes.getLength();
        }
        output->closeOutput();
        const OUString resolved = resolver->resolveEmbeddedObjectURL(objectID);
        const OUString prefix = u"vnd.sun.star.EmbeddedObject:"_ustr;
        if (!resolved.startsWith(prefix) || resolved.getLength() == prefix.getLength())
            throw std::runtime_error("Attachment was not stored in the document.");
        streamName = resolved.copy(prefix.getLength());
        shape.set(factory->createInstance(u"com.sun.star.drawing.OLE2Shape"_ustr), css::uno::UNO_QUERY_THROW);
        css::uno::Reference<css::beans::XPropertySet> properties(shape, css::uno::UNO_QUERY_THROW);
        // Before add(), SvxShape caches properties and applies them while it
        // creates the underlying SdrOle2Obj. No separate property undo entries
        // are emitted before the single insertion action below.
        properties->setPropertyValue(u"PersistName"_ustr, cpo::uno::Any(streamName));
        properties->setPropertyValue(u"Aspect"_ustr, cpo::uno::Any(sal_Int64(css::embed::Aspects::MSOLE_ICON)));
        properties->setPropertyValue(u"Graphic"_ustr, cpo::uno::Any(graphic));
        properties->setPropertyValue(u"Title"_ustr, cpo::uno::Any(FloeUNOString(displayName)));
        shape->setPosition(position);
        shape->setSize(size);
        page->add(shape);
        auto object = SdrObject::getSdrObjectFromXShape(shape);
        if (!object || !object->IsInserted()) throw std::runtime_error("The attachment object was not inserted.");
        // UNO insertion must also reach the active view. In Impress an
        // unselected newly added OLE shape otherwise waits for a later repaint.
        // Selection uses the normal native object handles for move/resize.
        css::uno::Reference<css::view::XSelectionSupplier> selection(controller, css::uno::UNO_QUERY_THROW);
        if (!selection->select(cpo::uno::Any(shape)))
            throw std::runtime_error("The inserted attachment could not be selected.");
        object->BroadcastObjectChange();
        oox::ole::SaveInteropProperties(model, streamName, nullptr, u"Package"_ustr);
        // XDrawPage.add() deliberately has no undo. The native new-object
        // action retains the shape/storage and gets the selected view ID.
        auto action = std::make_unique<FloeDrawingAttachmentUndo>(*object, model);
        undo->AddUndoAction(std::move(action));
        committed = true;
        owner->SetModified();
        try { lifetime->dispose(); } catch (...) { /* Insertion already succeeded. */ }
    } catch (...) {
        if (!committed) {
            // Remove only this provisional object. XDrawPage.remove() would
            // create an unrelated Delete undo entry, so use the object list.
            if (shape) {
                if (auto object = SdrObject::getSdrObjectFromXShape(shape)) {
                    if (auto list = object->getParentSdrObjListFromSdrObject())
                        list->RemoveObject(object->GetOrdNum());
                }
            }
            if (!streamName.isEmpty()) {
                try { owner->GetEmbeddedObjectContainer().RemoveEmbeddedObject(streamName, false); } catch (...) {}
            }
        }
        try { lifetime->dispose(); } catch (...) { /* Preserve insertion error. */ }
        throw;
    }
}

void FloeImportAttachment(const std::function<COKitDocument *()> &lookupDocument,
                              const std::string &sourceURL, const std::string &packageURL,
                              const std::string &iconURL, const std::string &displayName,
                              const std::string &identifier) {
    FloeWriteAttachmentPackage(sourceURL, packageURL, displayName);
    SolarMutexGuard guard;
    COKitDocument *document = lookupDocument();
    if (!document) throw std::runtime_error("Document closed during attachment preparation.");
    if (document->getDocumentType() == COKitDocumentType::TEXT)
        FloeInsertWordAttachment(document, packageURL, iconURL, displayName, identifier);
    else
        FloeInsertDrawingAttachment(document, packageURL, iconURL, displayName, identifier);
}

namespace {
struct FloePackageContents {
    OUString name;
    sal_uInt64 offset;
    sal_uInt32 size;
};

// Bound every length before seeking or allocating. Filenames are metadata,
// never trusted filesystem paths. Reuse SotStorage for compound-file parsing.
FloePackageContents FloeReadPackageHeader(SvStream &stream) {
    const auto end = stream.TellEnd();
    stream.Seek(0);
    sal_uInt32 total = 0;
    sal_uInt16 flags = 0;
    stream.ReadUInt32(total).ReadUInt16(flags);
    if (stream.GetError() || total > end - std::min<sal_uInt64>(end, 4) || flags != 2)
        throw std::runtime_error("Unsupported or damaged attachment package.");
    const sal_uInt64 packageEnd = sal_uInt64(total) + 4;
    auto ansi = [&]() {
        std::string value;
        while (value.size() < 32768 && stream.Tell() < packageEnd) {
            sal_uInt8 ch = 0; stream.ReadUChar(ch);
            if (stream.GetError()) break;
            if (!ch) return OUString(value.c_str(), value.size(), RTL_TEXTENCODING_MS_1252);
            value.push_back(static_cast<char>(ch));
        }
        throw std::runtime_error("Damaged attachment filename.");
    };
    const OUString label = ansi();
    const OUString filename = ansi();
    sal_uInt16 flags2 = 0, reserved = 0;
    sal_uInt32 commandBytes = 0, size = 0;
    stream.ReadUInt16(flags2).ReadUInt16(reserved).ReadUInt32(commandBytes);
    if (!commandBytes || commandBytes > 32768 || stream.Tell() > packageEnd || commandBytes > packageEnd - stream.Tell())
        throw std::runtime_error("Damaged attachment command metadata.");
    stream.Seek(stream.Tell() + commandBytes);
    stream.ReadUInt32(size);
    const auto offset = stream.Tell();
    if (stream.GetError() || offset > packageEnd || size > packageEnd - offset)
        throw std::runtime_error("Truncated attachment content.");
    OUString name = filename.isEmpty() ? label : filename;
    stream.Seek(offset + size);
    if (stream.Tell() < packageEnd) {
        // Package Unicode extension: command, label, original filename.
        for (int field = 0; field < 3; ++field) {
            sal_uInt32 length = 0; stream.ReadUInt32(length);
            if (stream.GetError() || length > 32768 || stream.Tell() > packageEnd || length * 2 > packageEnd - stream.Tell())
                throw std::runtime_error("Damaged attachment Unicode metadata.");
            std::u16string value(length, u'\0');
            for (auto &ch : value) { sal_uInt16 unit = 0; stream.ReadUInt16(unit); ch = unit; }
            if (field == 2 && length) name = OUString(value);
        }
    }
    if (stream.GetError()) throw std::runtime_error("Attachment metadata read failed.");
    return {name, offset, size};
}

SfxObjectShell *FloeOfficeShell(const std::function<COKitDocument *()> &lookupDocument) {
    auto document = lookupDocument();
    std::vector<int> views;
    if (!document || !document->getViewIds(views) || views.size() != 1)
        throw std::runtime_error("A single active Office view is required.");
    document->setView(views.front());
    auto shell = SfxViewShell::Current();
    if (!shell || !shell->GetObjectShell()) throw std::runtime_error("The Office view is unavailable.");
    return shell->GetObjectShell();
}

std::vector<OUString> FloeLivePackages(SfxObjectShell *shell) {
    std::vector<OUString> liveNames;
    css::uno::Reference<css::text::XTextEmbeddedObjectsSupplier> supplier(shell->GetModel(), css::uno::UNO_QUERY);
    if (supplier) {
        auto objects = supplier->getEmbeddedObjects();
        for (const auto &name : objects->getElementNames()) {
            css::uno::Reference<css::beans::XPropertySet> properties(objects->getByName(name), css::uno::UNO_QUERY_THROW);
            css::uno::Reference<css::embed::XEmbeddedObject> embedded(properties->getPropertyValue(u"EmbeddedObject"_ustr), css::uno::UNO_QUERY);
            if (embedded) liveNames.push_back(shell->GetEmbeddedObjectContainer().GetEmbeddedObjectName(embedded));
        }
    } else {
        css::uno::Reference<css::drawing::XDrawPagesSupplier> pagesSupplier(shell->GetModel(), css::uno::UNO_QUERY_THROW);
        auto pages = pagesSupplier->getDrawPages();
        std::function<void(const css::uno::Reference<css::drawing::XShapes> &)> collect;
        collect = [&](const css::uno::Reference<css::drawing::XShapes> &shapes) {
            for (sal_Int32 index = 0; index < shapes->getCount(); ++index) {
                auto item = shapes->getByIndex(index);
                css::uno::Reference<css::drawing::XShapes> children(item, css::uno::UNO_QUERY);
                if (children) collect(children);
                css::uno::Reference<css::beans::XPropertySet> properties(item, css::uno::UNO_QUERY);
                if (!properties || !properties->getPropertySetInfo()->hasPropertyByName(u"PersistName"_ustr)) continue;
                OUString name;
                if (properties->getPropertyValue(u"PersistName"_ustr) >>= name) liveNames.push_back(name);
            }
        };
        for (sal_Int32 index = 0; index < pages->getCount(); ++index)
            collect(css::uno::Reference<css::drawing::XShapes>(pages->getByIndex(index), css::uno::UNO_QUERY_THROW));
    }
    std::vector<OUString> result;
    for (const auto &storageName : liveNames) {
        if (storageName.isEmpty() || !shell->GetStorage()->isStreamElement(storageName)) continue;
        if (std::find(result.begin(), result.end(), storageName) != result.end()) continue;
        // On mobile the UNO object may be a generic foreign-object wrapper.
        // Identify Package from its actual compound storage, not that wrapper's
        // class ID. Native charts/subdocuments use their own storage types.
        // A loaded embedded object can own the live writable stream. Clone the
        // engine's flushed content without acquiring a second stream owner.
        auto stream = shell->GetStorage()->cloneStreamElement(storageName);
        auto input = utl::UcbStreamHelper::CreateStream(stream->getInputStream());
        if (!input || !SotStorage::IsStorageFile(input.get())) continue;
        rtl::Reference<SotStorage> storage = new SotStorage(*input);
        if (storage->GetError()) throw std::runtime_error("Embedded object storage is damaged.");
        if (storage->GetClassName() == SvGlobalName(0x0003000c, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46))
            result.push_back(storageName);
    }
    return result;
}

FloeEmbeddedAttachment FloeReadPackage(SfxObjectShell *shell, const OUString &identifier,
                                      const std::string *destinationURL) {
    auto stream = shell->GetStorage()->cloneStreamElement(identifier);
    auto input = utl::UcbStreamHelper::CreateStream(stream->getInputStream());
    if (!input) throw std::runtime_error("Attachment storage is unavailable.");
    rtl::Reference<SotStorage> storage = new SotStorage(*input);
    auto native = storage->OpenSotStream(u"\001Ole10Native"_ustr, StreamMode::READ);
    if (storage->GetError() || !native || native->GetError()) throw std::runtime_error("Attachment package is unavailable.");
    auto contents = FloeReadPackageHeader(*native);
    if (destinationURL) {
        SvFileStream output(FloeUNOString(*destinationURL), StreamMode::WRITE | StreamMode::TRUNC);
        native->Seek(contents.offset);
        sal_uInt64 remaining = contents.size;
        std::array<char, 65536> buffer;
        while (remaining) {
            const auto count = static_cast<std::size_t>(std::min<sal_uInt64>(remaining, buffer.size()));
            if (native->ReadBytes(buffer.data(), count) != count || output.WriteBytes(buffer.data(), count) != count)
                throw std::runtime_error("Attachment export did not finish.");
            remaining -= count;
        }
        output.Flush();
        if (native->GetError() || output.GetError()) throw std::runtime_error("Attachment export could not be saved.");
    }
    return {OUStringToOString(identifier, RTL_TEXTENCODING_UTF8).getStr(),
            OUStringToOString(contents.name, RTL_TEXTENCODING_UTF8).getStr(), contents.size};
}
}

std::vector<FloeEmbeddedAttachment> FloeListAttachments(const std::function<COKitDocument *()> &lookupDocument) {
    SolarMutexGuard guard;
    auto shell = FloeOfficeShell(lookupDocument);
    std::vector<FloeEmbeddedAttachment> result;
    for (const auto &name : FloeLivePackages(shell)) result.push_back(FloeReadPackage(shell, name, nullptr));
    return result;
}

void FloeExportAttachment(const std::function<COKitDocument *()> &lookupDocument,
                             const std::string &identifier, const std::string &destinationURL) {
    SolarMutexGuard guard;
    auto shell = FloeOfficeShell(lookupDocument);
    const auto names = FloeLivePackages(shell);
    const auto name = FloeUNOString(identifier);
    if (std::find(names.begin(), names.end(), name) == names.end())
        throw std::runtime_error("This attachment is no longer present. Refresh the attachment list.");
    FloeReadPackage(shell, name, &destinationURL);
}

#include <com/sun/star/frame/XStorable.hpp>
void FloeExportDocument(const std::function<COKitDocument *()> &lookupDocument,
                       const std::string &destinationURL, const std::string &format) {
    SolarMutexGuard guard;
    auto shell = FloeOfficeShell(lookupDocument);
    auto document = lookupDocument();
    if (!document) throw std::runtime_error("Document closed before export.");
    OUString filter;
    switch (document->getDocumentType()) {
        case COKitDocumentType::TEXT:
            if (format == "pdf") filter = u"writer_pdf_Export"_ustr;
            else if (format == "docx") filter = u"Office Open XML Text"_ustr;
            else if (format == "odt") filter = u"writer8"_ustr;
            else if (format == "rtf") filter = u"Rich Text Format"_ustr;
            else if (format == "txt") filter = u"Text (encoded)"_ustr;
            break;
        case COKitDocumentType::PRESENTATION:
            if (format == "pdf") filter = u"impress_pdf_Export"_ustr;
            else if (format == "pptx") filter = u"Impress MS PowerPoint 2007 XML"_ustr;
            else if (format == "odp") filter = u"impress8"_ustr;
            break;
        case COKitDocumentType::SPREADSHEET:
            if (format == "pdf") filter = u"calc_pdf_Export"_ustr;
            else if (format == "xlsx") filter = u"Calc MS Excel 2007 XML"_ustr;
            else if (format == "ods") filter = u"calc8"_ustr;
            break;
        default: break;
    }
    if (filter.isEmpty()) throw std::runtime_error("Unsupported document export format.");
    css::uno::Reference<css::frame::XStorable> storable(shell->GetModel(), css::uno::UNO_QUERY_THROW);
    cpo::uno::Sequence<css::beans::PropertyValue> properties{
        comphelper::makePropertyValue(u"FilterName"_ustr, filter),
        comphelper::makePropertyValue(u"Overwrite"_ustr, false),
        comphelper::makePropertyValue(u"FilterOptions"_ustr, format == "txt" ? u"UTF8,LF"_ustr : OUString())
    };
    storable->storeToURL(FloeUNOString(destinationURL), properties);
}
