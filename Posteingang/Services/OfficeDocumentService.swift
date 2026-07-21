import Compression
import Foundation

enum OfficeDocumentError: LocalizedError {
    case unsupportedLegacyFormat
    case invalidDocument
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .unsupportedLegacyFormat:
            "Alte Office-Binärformate können angezeigt, aber noch nicht lokal ausgelesen werden. Bitte als DOCX, XLSX, PPTX oder PDF speichern."
        case .invalidDocument:
            "Das Office-Dokument ist beschädigt oder kein gültiges Open-XML-Dokument."
        case .noReadableText:
            "Im Office-Dokument wurde kein lesbarer Text gefunden."
        }
    }
}

struct OfficeDocumentService {
    nonisolated init() {}

    nonisolated func recognize(url: URL) throws -> RecognitionResult {
        let ext = url.pathExtension.lowercased()
        return try recognize(data: Data(contentsOf: url, options: .mappedIfSafe), filenameExtension: ext)
    }

    nonisolated func recognize(data: Data, filenameExtension ext: String) throws -> RecognitionResult {
        guard ["docx", "xlsx", "pptx"].contains(ext) else {
            throw OfficeDocumentError.unsupportedLegacyFormat
        }

        let archive = try SimpleZIPArchive(data: data)
        let names: [String]
        switch ext {
        case "docx":
            names = archive.names.filter {
                $0 == "word/document.xml"
                    || $0.hasPrefix("word/header")
                    || $0.hasPrefix("word/footer")
            }.sorted()
        case "xlsx":
            names = archive.names.filter {
                $0 == "xl/sharedStrings.xml" || $0.hasPrefix("xl/worksheets/sheet")
            }.sorted(by: naturalOrder)
        default:
            names = archive.names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted(by: naturalOrder)
        }

        let sections = try names.compactMap { name -> String? in
            guard let data = try archive.data(for: name),
                  let xml = String(data: data, encoding: .utf8) else { return nil }
            let text = readableText(fromXML: xml)
            guard !text.isEmpty else { return nil }
            return "\(sectionTitle(for: name))\n\(text)"
        }
        guard !sections.isEmpty else { throw OfficeDocumentError.noReadableText }
        return RecognitionResult(text: sections.joined(separator: "\n\n"), pageCount: max(1, sections.count))
    }

    nonisolated func previewHTML(url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        guard ["docx", "xlsx", "pptx"].contains(ext) else {
            throw OfficeDocumentError.unsupportedLegacyFormat
        }
        let archive = try SimpleZIPArchive(data: Data(contentsOf: url, options: .mappedIfSafe))
        let body: String
        switch ext {
        case "docx":
            guard let data = try archive.data(for: "word/document.xml") else {
                throw OfficeDocumentError.invalidDocument
            }
            body = DOCXHTMLParser.parse(data: data)
        case "xlsx":
            body = try xlsxHTML(from: archive)
        default:
            body = try pptxHTML(from: archive)
        }
        return htmlDocument(body: body, spreadsheet: ext == "xlsx")
    }
}

private nonisolated func htmlDocument(body: String, spreadsheet: Bool) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root { color-scheme: light dark; }
    body { margin: 0; padding: 24px; font: 15px -apple-system, BlinkMacSystemFont, sans-serif;
           color: CanvasText; background: Canvas; line-height: 1.45; }
    .document { max-width: \(spreadsheet ? "none" : "900px"); margin: 0 auto; }
    .page, .slide { box-sizing: border-box; margin: 0 auto 22px; padding: 34px 42px;
                    max-width: 850px; min-height: 180px; background: color-mix(in srgb, Canvas 96%, CanvasText 4%);
                    border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); border-radius: 8px; }
    p { margin: 0 0 .65em; white-space: pre-wrap; }
    table { border-collapse: collapse; margin: 0 0 24px; min-width: max-content; }
    th, td { border: 1px solid color-mix(in srgb, CanvasText 28%, transparent); padding: 5px 8px;
             text-align: left; vertical-align: top; white-space: pre-wrap; }
    th { position: sticky; top: 0; background: color-mix(in srgb, Canvas 88%, CanvasText 12%); }
    .sheet { overflow: auto; margin-bottom: 30px; }
    h2 { margin-top: 0; }
    </style></head><body><main class="document">\(body)</main></body></html>
    """
}

private nonisolated final class DOCXHTMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private var html = #"<div class="page">"#
    private var readingText = false
    private var runIsBold = false
    private var runIsItalic = false
    private var runIsUnderlined = false
    private var runSpanOpen = false

    static func parse(data: Data) -> String {
        let delegate = DOCXHTMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.html + "</div>"
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "tbl": html += "<table>"
        case "tr": html += "<tr>"
        case "tc": html += "<td>"
        case "p":
            let alignment = attributeDict["w:val"].map { " style=\"text-align:\(htmlEscape($0))\"" } ?? ""
            html += "<p\(alignment)>"
        case "r":
            runIsBold = false; runIsItalic = false; runIsUnderlined = false; runSpanOpen = false
        case "b": runIsBold = true
        case "i": runIsItalic = true
        case "u": runIsUnderlined = true
        case "t":
            readingText = true
            let styles = [runIsBold ? "font-weight:600" : nil,
                          runIsItalic ? "font-style:italic" : nil,
                          runIsUnderlined ? "text-decoration:underline" : nil]
                .compactMap { $0 }.joined(separator: ";")
            if !styles.isEmpty { html += "<span style=\"\(styles)\">"; runSpanOpen = true }
        case "tab": html += "&#9;"
        case "br":
            if attributeDict["w:type"] == "page" { html += #"</div><div class="page">"# }
            else { html += "<br>" }
        case "lastRenderedPageBreak": html += #"</div><div class="page">"#
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if readingText { html += htmlEscape(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "tbl": html += "</table>"
        case "tr": html += "</tr>"
        case "tc": html += "</td>"
        case "p": html += "</p>"
        case "t":
            if runSpanOpen { html += "</span>"; runSpanOpen = false }
            readingText = false
        default: break
        }
    }
}

private nonisolated func xlsxHTML(from archive: SimpleZIPArchive) throws -> String {
    let sharedStrings: [String]
    if let data = try archive.data(for: "xl/sharedStrings.xml") {
        sharedStrings = XMLTextCollector.collect(data: data, itemElement: "si")
    } else {
        sharedStrings = []
    }
    let sheets = archive.names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
        .sorted(by: naturalOrder)
    guard !sheets.isEmpty else { throw OfficeDocumentError.noReadableText }
    return try sheets.enumerated().map { index, name in
        guard let data = try archive.data(for: name) else { return "" }
        let rows = XLSXSheetParser.parse(data: data, sharedStrings: sharedStrings)
        let table = rows.map { row in
            "<tr>" + row.map { "<td>\(htmlEscape($0))</td>" }.joined() + "</tr>"
        }.joined()
        return "<section class=\"sheet\"><h2>Tabelle \(index + 1)</h2><table>\(table)</table></section>"
    }.joined()
}

private nonisolated func pptxHTML(from archive: SimpleZIPArchive) throws -> String {
    let slides = archive.names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        .sorted(by: naturalOrder)
    guard !slides.isEmpty else { throw OfficeDocumentError.noReadableText }
    return try slides.enumerated().map { index, name in
        guard let data = try archive.data(for: name), let xml = String(data: data, encoding: .utf8) else { return "" }
        let text = readableText(fromXML: xml).split(separator: "\n").map { "<p>\(htmlEscape(String($0)))</p>" }.joined()
        return "<section class=\"slide\"><h2>Folie \(index + 1)</h2>\(text)</section>"
    }.joined()
}

private nonisolated func htmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private nonisolated final class XMLTextCollector: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let itemElement: String
    private var collecting = false
    private var current = ""
    private(set) var values: [String] = []

    init(itemElement: String) { self.itemElement = itemElement }
    static nonisolated func collect(data: Data, itemElement: String) -> [String] {
        let delegate = XMLTextCollector(itemElement: itemElement)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == itemElement { collecting = true; current = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { current += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == itemElement { values.append(current); collecting = false }
    }
}

private nonisolated final class XLSXSheetParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var row: [String] = []
    private var cellColumn = 0
    private var cellType: String?
    private var readingValue = false
    private var value = ""

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }
    static nonisolated func parse(data: Data, sharedStrings: [String]) -> [[String]] {
        let delegate = XLSXSheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "row" { row = [] }
        if elementName == "c" {
            cellColumn = Self.columnIndex(from: attributeDict["r"] ?? "A1")
            cellType = attributeDict["t"]
            value = ""
        }
        if elementName == "v" || elementName == "t" { readingValue = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if readingValue { value += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "v" || elementName == "t" { readingValue = false }
        if elementName == "c" {
            while row.count < cellColumn { row.append("") }
            let resolved = cellType == "s" ? (Int(value).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? value) : value
            if row.count == cellColumn { row.append(resolved) } else { row[cellColumn] = resolved }
        }
        if elementName == "row" { rows.append(row) }
    }
    private static func columnIndex(from reference: String) -> Int {
        reference.prefix(while: { $0.isLetter }).reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) } - 1
    }
}

private struct SimpleZIPArchive {
    private struct Entry {
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let source: Data
    private let entries: [String: Entry]
    nonisolated var names: [String] { Array(entries.keys) }

    nonisolated init(data: Data) throws {
        source = data
        guard let eocd = data.lastRange(of: 0x06054B50),
              let count = data.uint16(at: eocd + 10),
              let centralOffset = data.uint32(at: eocd + 16) else {
            throw OfficeDocumentError.invalidDocument
        }

        var result: [String: Entry] = [:]
        var offset = Int(centralOffset)
        for _ in 0..<Int(count) {
            guard data.uint32(at: offset) == 0x02014B50,
                  let method = data.uint16(at: offset + 10),
                  let compressedSize = data.uint32(at: offset + 20),
                  let uncompressedSize = data.uint32(at: offset + 24),
                  let nameLength = data.uint16(at: offset + 28),
                  let extraLength = data.uint16(at: offset + 30),
                  let commentLength = data.uint16(at: offset + 32),
                  let localOffset = data.uint32(at: offset + 42) else {
                throw OfficeDocumentError.invalidDocument
            }
            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameEnd <= data.count,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw OfficeDocumentError.invalidDocument
            }
            result[name] = Entry(
                compressionMethod: method,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localOffset)
            )
            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }
        entries = result
    }

    nonisolated func data(for name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let offset = entry.localHeaderOffset
        guard source.uint32(at: offset) == 0x04034B50,
              let nameLength = source.uint16(at: offset + 26),
              let extraLength = source.uint16(at: offset + 28) else {
            throw OfficeDocumentError.invalidDocument
        }
        let start = offset + 30 + Int(nameLength) + Int(extraLength)
        let end = start + entry.compressedSize
        guard start >= 0, end <= source.count else { throw OfficeDocumentError.invalidDocument }
        let compressed = Data(source[start..<end])
        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            var output = Data(count: entry.uncompressedSize)
            let decoded = output.withUnsafeMutableBytes { outputBuffer in
                compressed.withUnsafeBytes { inputBuffer in
                    compression_decode_buffer(
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        entry.uncompressedSize,
                        inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        entry.compressedSize,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decoded > 0 else { throw OfficeDocumentError.invalidDocument }
            output.count = decoded
            return output
        default:
            throw OfficeDocumentError.invalidDocument
        }
    }
}

private extension Data {
    nonisolated func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return self[offset..<offset + 2].enumerated().reduce(0) { $0 | UInt16($1.element) << ($1.offset * 8) }
    }

    nonisolated func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return self[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }

    nonisolated func lastRange(of signature: UInt32) -> Int? {
        let bytes = [UInt8(signature & 0xff), UInt8((signature >> 8) & 0xff), UInt8((signature >> 16) & 0xff), UInt8((signature >> 24) & 0xff)]
        guard count >= bytes.count else { return nil }
        let lowerBound = Swift.max(0, count - 65_557)
        for offset in stride(from: count - 4, through: lowerBound, by: -1) {
            if Array(self[offset..<offset + 4]) == bytes { return offset }
        }
        return nil
    }
}

private nonisolated func readableText(fromXML xml: String) -> String {
    var text = xml
        .replacingOccurrences(of: #"(?i)</(?:w:p|a:p|row|si)>"#, with: "\n", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)<(?:w:tab|a:br)[^>]*/>"#, with: "\t", options: .regularExpression)
        .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'"]
    for (entity, replacement) in entities { text = text.replacingOccurrences(of: entity, with: replacement) }
    return text
        .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private nonisolated func sectionTitle(for name: String) -> String {
    if name.contains("slides/slide") { return "Folie \(number(in: name) ?? 1)" }
    if name.contains("worksheets/sheet") { return "Tabelle \(number(in: name) ?? 1)" }
    if name.contains("header") { return "Kopfzeile" }
    if name.contains("footer") { return "Fußzeile" }
    if name.contains("sharedStrings") { return "Tabellentexte" }
    return "Dokument"
}

private nonisolated func number(in text: String) -> Int? {
    let digits = text.split(whereSeparator: { !$0.isNumber }).last(where: { !$0.isEmpty })
    return digits.flatMap { Int($0) }
}

private nonisolated func naturalOrder(_ lhs: String, _ rhs: String) -> Bool {
    (number(in: lhs) ?? 0) < (number(in: rhs) ?? 0)
}
