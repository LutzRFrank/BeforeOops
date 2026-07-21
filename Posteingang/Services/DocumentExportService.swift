import CoreText
import Foundation
import PDFKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DocumentExportService {
    func makeIntelligentPDF(for document: InboxDocument, originalURL: URL) throws -> URL {
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeFilename(document.title))-mit-Analyse")
            .appendingPathExtension("pdf")

        let result = PDFDocument()
        if let original = PDFDocument(url: originalURL) {
            for index in 0..<original.pageCount {
                if let page = original.page(at: index) {
                    result.insert(page, at: result.pageCount)
                }
            }
        } else if let imagePage = imagePage(from: originalURL) {
            result.insert(imagePage, at: result.pageCount)
        } else {
            throw ExportError.unsupportedOriginal
        }

        let appendix = try analysisAppendix(for: document)
        for index in 0..<appendix.pageCount {
            if let page = appendix.page(at: index) {
                result.insert(page, at: result.pageCount)
            }
        }

        guard result.write(to: exportURL) else {
            throw ExportError.couldNotWrite
        }
        return exportURL
    }

    private func analysisAppendix(for document: InboxDocument) throws -> PDFDocument {
        let sections = [
            "INTELLIGENTE DOKUMENTANALYSE",
            "Dokument: \(document.title)",
            "Typ: \(document.analyzedDocumentType ?? "Nicht bestimmt")",
            "",
            "ZUSAMMENFASSUNG",
            document.analysisSummary ?? "Keine Analyse verfügbar.",
            "",
            "ERKANNTER TERMIN",
            [document.actionableDateMeaning, document.actionableDateText]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ": ")
                .nilIfEmpty ?? "Kein relevanter Termin erkannt.",
            "",
            "EMPFOHLENE AKTION",
            document.recommendedAction?.nilIfEmpty ?? "Keine Aktion vorgeschlagen."
        ]

        let text = sections.joined(separator: "\n")
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ExportError.couldNotWrite
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.couldNotWrite
        }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 11, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0

        repeat {
            context.beginPDFPage(nil)
            let textRect = CGRect(x: 54, y: 54, width: mediaBox.width - 108, height: mediaBox.height - 108)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < attributed.length

        context.closePDF()
        guard let pdf = PDFDocument(data: data as Data) else {
            throw ExportError.couldNotWrite
        }
        return pdf
    }

    private func imagePage(from url: URL) -> PDFPage? {
        #if os(iOS)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return PDFPage(image: image)
        #elseif os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return PDFPage(image: image)
        #endif
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "[^a-zA-Z0-9äöüÄÖÜß_-]+", with: "-", options: .regularExpression)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private enum ExportError: LocalizedError {
    case unsupportedOriginal
    case couldNotWrite

    var errorDescription: String? {
        switch self {
        case .unsupportedOriginal: "Das Original konnte nicht in das Export-PDF übernommen werden."
        case .couldNotWrite: "Das Export-PDF konnte nicht erstellt werden."
        }
    }
}
