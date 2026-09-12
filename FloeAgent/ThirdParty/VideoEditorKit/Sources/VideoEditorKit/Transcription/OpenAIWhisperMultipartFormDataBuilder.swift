import Foundation

struct OpenAIWhisperMultipartFormDataBuilder {

    // MARK: - Public Properties

    struct FilePart: Sendable {
        let fieldName: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    let boundary: String

    var contentTypeHeaderValue: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    // MARK: - Initializer

    init(_ boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    // MARK: - Public Methods

    func makeBody(
        fields: [String: String],
        repeatedFields: [String: [String]] = [:],
        filePart: FilePart
    ) -> Data {
        var body = Data()

        for field in fields.sorted(by: { $0.key < $1.key }) {
            appendField(named: field.key, value: field.value, to: &body)
        }

        for field in repeatedFields.sorted(by: { $0.key < $1.key }) {
            for value in field.value {
                appendField(named: field.key, value: value, to: &body)
            }
        }

        appendFilePart(filePart, to: &body)
        append("--\(boundary)--\r\n", to: &body)
        return body
    }

    // MARK: - Private Methods

    private func appendField(named name: String, value: String, to body: inout Data) {
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", to: &body)
        append("\(value)\r\n", to: &body)
    }

    private func appendFilePart(_ filePart: FilePart, to body: inout Data) {
        append("--\(boundary)\r\n", to: &body)
        append(
            "Content-Disposition: form-data; name=\"\(filePart.fieldName)\"; filename=\"\(filePart.filename)\"\r\n",
            to: &body
        )
        append("Content-Type: \(filePart.mimeType)\r\n\r\n", to: &body)
        body.append(filePart.data)
        append("\r\n", to: &body)
    }

    private func append(_ string: String, to body: inout Data) {
        body.append(Data(string.utf8))
    }

}
