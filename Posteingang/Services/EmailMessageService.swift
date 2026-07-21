import Foundation
import UniformTypeIdentifiers

enum EmailMessageError: LocalizedError {
    case unreadableMessage
    case emptyMessage

    var errorDescription: String? {
        switch self {
        case .unreadableMessage:
            "Die E-Mail konnte nicht gelesen werden."
        case .emptyMessage:
            "Die E-Mail enthält keinen lesbaren Text."
        }
    }
}

struct ParsedEmailMessage: Sendable {
    let subject: String?
    let text: String
    let attachments: [EmailAttachment]
}

struct EmailAttachment: Sendable {
    let filename: String
    let data: Data
    let contentTypeIdentifier: String
}

struct EmailMessageService {
    nonisolated init() {}

    nonisolated func parse(url: URL) throws -> ParsedEmailMessage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw EmailMessageError.emptyMessage }
        return try parse(data: data)
    }

    nonisolated func parse(data: Data) throws -> ParsedEmailMessage {
        guard let source = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw EmailMessageError.unreadableMessage
        }

        let entity = MIMEEntity(source)
        let subject = decodedHeader(entity.headers["subject"])
        let sender = decodedHeader(entity.headers["from"])
        let recipients = decodedHeader(entity.headers["to"])
        let date = decodedHeader(entity.headers["date"])
        let body = extractReadableText(from: entity)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var sections: [String] = []
        if let subject, !subject.isEmpty { sections.append("Betreff: \(subject)") }
        if let sender, !sender.isEmpty { sections.append("Von: \(sender)") }
        if let recipients, !recipients.isEmpty { sections.append("An: \(recipients)") }
        if let date, !date.isEmpty { sections.append("Datum: \(date)") }
        if !body.isEmpty { sections.append(body) }
        guard !sections.isEmpty else { throw EmailMessageError.emptyMessage }

        return ParsedEmailMessage(
            subject: subject,
            text: sections.joined(separator: "\n\n"),
            attachments: extractSupportedAttachments(from: entity)
        )
    }
}

private struct MIMEEntity {
    let headers: [String: String]
    let body: String

    nonisolated init(_ source: String) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        let headerText = parts.first ?? ""
        body = parts.dropFirst().joined(separator: "\n\n")
        headers = Self.parseHeaders(headerText)
    }

    private nonisolated static func parseHeaders(_ source: String) -> [String: String] {
        var unfolded: [String] = []
        for line in source.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }

        var result: [String: String] = [:]
        for line in unfolded {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }
}

private nonisolated func extractReadableText(from entity: MIMEEntity) -> String {
    let contentType = entity.headers["content-type"]?.lowercased() ?? "text/plain"
    if contentType.hasPrefix("multipart/"),
       let boundary = parameter(named: "boundary", in: entity.headers["content-type"] ?? "") {
        let parts = entity.body.components(separatedBy: "--\(boundary)")
            .dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--") }
            .map(MIMEEntity.init)

        let plain = parts.filter {
            ($0.headers["content-type"]?.lowercased() ?? "text/plain").hasPrefix("text/plain")
        }.map(extractReadableText)
        if let text = plain.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return text
        }
        return parts.map(extractReadableText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    guard contentType.hasPrefix("text/plain") || contentType.hasPrefix("text/html") else { return "" }
    let decoded = decodeBody(entity.body, encoding: entity.headers["content-transfer-encoding"])
    return contentType.hasPrefix("text/html") ? plainText(fromHTML: decoded) : decoded
}

private nonisolated func extractSupportedAttachments(from entity: MIMEEntity) -> [EmailAttachment] {
    let contentTypeHeader = entity.headers["content-type"] ?? ""
    let contentType = contentTypeHeader.lowercased()
    if contentType.hasPrefix("multipart/"),
       let boundary = parameter(named: "boundary", in: contentTypeHeader) {
        return entity.body.components(separatedBy: "--\(boundary)")
            .dropFirst()
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--") }
            .flatMap { extractSupportedAttachments(from: MIMEEntity($0)) }
    }

    let disposition = entity.headers["content-disposition"] ?? ""
    let filename = parameter(named: "filename", in: disposition)
        ?? parameter(named: "name", in: contentTypeHeader)
        ?? "Anhang.pdf"
    let decodedFilename = decodedHeader(filename) ?? filename
    let filenameExtension = URL(fileURLWithPath: decodedFilename).pathExtension.lowercased()
    let supportedExtensions = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx"]
    guard supportedExtensions.contains(filenameExtension),
          let decodedData = decodedBodyData(entity.body, encoding: entity.headers["content-transfer-encoding"]) else { return [] }
    let data = filenameExtension == "pdf" ? normalizedPDFData(decodedData) : decodedData
    guard let data, !data.isEmpty else { return [] }
    let type = UTType(filenameExtension: filenameExtension) ?? .data
    return [EmailAttachment(
        filename: decodedFilename,
        data: data,
        contentTypeIdentifier: type.identifier
    )]
}

private nonisolated func decodedBodyData(_ body: String, encoding: String?) -> Data? {
    switch encoding?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
    case "base64":
        return Data(base64Encoded: body, options: .ignoreUnknownCharacters)
    case "quoted-printable":
        return decodeQuotedPrintable(body).data(using: .isoLatin1)
    default:
        return body.data(using: .isoLatin1)
    }
}

private nonisolated func normalizedPDFData(_ data: Data?) -> Data? {
    guard let data, !data.isEmpty,
          let signature = "%PDF".data(using: .ascii),
          let start = data.range(of: signature)?.lowerBound else { return nil }
    return Data(data[start...])
}

private nonisolated func decodeBody(_ body: String, encoding: String?) -> String {
    switch encoding?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
    case "base64":
        let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: compact) else { return body }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? body
    case "quoted-printable":
        return decodeQuotedPrintable(body)
    default:
        return body
    }
}

private nonisolated func decodeQuotedPrintable(_ source: String) -> String {
    let bytes = Array(source.replacingOccurrences(of: "=\n", with: "").utf8)
    var output: [UInt8] = []
    var index = 0
    while index < bytes.count {
        if bytes[index] == 61, index + 2 < bytes.count,
           let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
            output.append(high * 16 + low)
            index += 3
        } else {
            output.append(bytes[index])
            index += 1
        }
    }
    return String(data: Data(output), encoding: .utf8)
        ?? String(data: Data(output), encoding: .isoLatin1)
        ?? source
}

private nonisolated func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
}

private nonisolated func decodedHeader(_ value: String?) -> String? {
    guard let value else { return nil }
    let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    var result = value
    for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
        guard let whole = Range(match.range(at: 0), in: value),
              let charsetRange = Range(match.range(at: 1), in: value),
              let modeRange = Range(match.range(at: 2), in: value),
              let contentRange = Range(match.range(at: 3), in: value) else { continue }
        let charset = String(value[charsetRange]).lowercased()
        let mode = value[modeRange].lowercased()
        let content = String(value[contentRange])
        let data: Data?
        if mode == "b" {
            data = Data(base64Encoded: content)
        } else {
            data = decodeQuotedPrintable(content.replacingOccurrences(of: "_", with: " ")).data(using: .utf8)
        }
        guard let data else { continue }
        let encoding: String.Encoding = charset.contains("iso-8859-1") ? .isoLatin1 : .utf8
        if let decoded = String(data: data, encoding: encoding) {
            result.replaceSubrange(whole, with: decoded)
        }
    }
    return result
}

private nonisolated func parameter(named name: String, in header: String) -> String? {
    let pattern = "(?:^|;)\\s*\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]+)\"|([^;\\s]+))"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
    for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
        if let range = Range(match.range(at: index), in: header) { return String(header[range]) }
    }
    return nil
}

private nonisolated func plainText(fromHTML html: String) -> String {
    var text = html
        .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)</(p|div|li|tr|h[1-6])>"#, with: "\n", options: .regularExpression)
        .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
    for (entity, replacement) in entities { text = text.replacingOccurrences(of: entity, with: replacement) }
    return text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
}
