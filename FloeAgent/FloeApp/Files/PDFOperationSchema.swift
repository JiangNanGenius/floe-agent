import Foundation

enum PDFOperationSchema {
    /// Compose one canonical edit schema; advanced operations are only loaded
    /// with the PDF tool group, never injected into unrelated model requests.
    static func add(to base: String) -> String {
        let operation = #"""
        {"type":"array","minItems":1,"maxItems":30,"items":{"type":"object","properties":{
          "action":{"type":"string","enum":["reorderPages","cropPage","insertBlankPage","addAnnotation","updateAnnotation","removeAnnotation","createField","setField","removeField","setMetadata","setBookmarks","flattenAnnotations","searchableOCR","rasterRedact","replaceRegion","addText","insertImage","replaceImage","removeImage"]},
          "imagePath":{"type":"string","description":"Workspace-relative image for insertImage/replaceImage; stretched to bounds"},
          "expectedObjectCount":{"type":"integer","minimum":1,"maximum":500,"description":"Required for replaceRegion/replaceImage/removeImage. Exact count of fully contained native top-level text/image objects; partial or nested matches fail"},
          "page":{"type":"integer","minimum":1},
          "bounds":{"type":"array","minItems":4,"maxItems":4,"items":{"type":"number"},"description":"[x,y,width,height] unrotated PDF points, lower-left origin"},
          "pages":{"type":"array","maxItems":500,"items":{"type":"integer","minimum":1}},
          "annotationIndex":{"type":"integer","minimum":0,"description":"0-based index from inspect at expectedSHA256"},
          "kind":{"type":"string","enum":["note","freeText","highlight","underline","strikeOut","square","circle","ink","line","text","checkbox","choice"]},
          "text":{"type":"string","maxLength":16000},"fieldName":{"type":"string","maxLength":200},"checked":{"type":"boolean"},
          "choices":{"type":"array","maxItems":100,"items":{"type":"string","maxLength":200}},
          "color":{"type":"array","minItems":3,"maxItems":4,"items":{"type":"number","minimum":0,"maximum":1}},
          "fontSize":{"type":"number","minimum":6,"maximum":96},
          "points":{"type":"array","maxItems":500,"items":{"type":"array","minItems":2,"maxItems":2,"items":{"type":"number"}}},
          "metadata":{"type":"object","properties":{"title":{"type":"string"},"author":{"type":"string"},"subject":{"type":"string"},"creator":{"type":"string"},"keywords":{"type":"string"}},"additionalProperties":false},
          "bookmarks":{"type":"array","maxItems":200,"items":{"type":"object","properties":{"title":{"type":"string","maxLength":200},"page":{"type":"integer","minimum":1}},"required":["title","page"],"additionalProperties":false}},
          "regions":{"type":"array","maxItems":100,"items":{"type":"object","properties":{"page":{"type":"integer","minimum":1},"bounds":{"type":"array","minItems":4,"maxItems":4,"items":{"type":"number"}}},"required":["page","bounds"],"additionalProperties":false}},
          "acceptRasterization":{"type":"boolean","description":"Set true only after the user accepts image-only page rebuilding and loss of interactive/vector content; OCR adds a new recognized text layer"},
          "acceptFlattening":{"type":"boolean","description":"Explicit acceptance that flattenAnnotations removes annotation and form interactivity while preserving page content; not secure redaction"},
          "languages":{"type":"array","maxItems":5,"items":{"type":"string"}}
        },"required":["action"],"additionalProperties":false}}
        """#
        guard var schema = try? JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any],
              var properties = schema["properties"] as? [String: Any],
              let operations = try? JSONSerialization.jsonObject(with: Data(operation.utf8)) else {
            preconditionFailure("Invalid compiled PDF operation schema")
        }
        properties["operations"] = operations
        properties.removeValue(forKey: "userPassword")
        properties.removeValue(forKey: "ownerPassword")
        for key in ["userPasswordRef", "ownerPasswordRef"] {
            properties[key] = ["type": "string", "description": "Saved ⟨credential:UUID⟩ reference for PDF output protection; never plaintext"]
        }
        properties["expectedSHA256"] = ["type": "string", "pattern": "^[0-9a-fA-F]{64}$", "description": "Required for operations; sha256 from inspect"]
        schema["properties"] = properties
        return String(decoding: try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
    }
}
