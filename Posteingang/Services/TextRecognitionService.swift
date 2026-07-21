import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum TextRecognitionError: LocalizedError {
    case cannotOpenDocument
    case cannotRenderPage(Int)
    case unsupportedType

    var errorDescription: String? {
        switch self {
        case .cannotOpenDocument:
            "Das Dokument konnte für die Texterkennung nicht geöffnet werden."
        case .cannotRenderPage(let page):
            "Seite \(page) konnte nicht für die Texterkennung aufbereitet werden."
        case .unsupportedType:
            "Dieses Dateiformat kann nicht per OCR verarbeitet werden."
        }
    }
}

struct RecognitionResult: Sendable {
    let text: String
    let pageCount: Int
    let attachmentCount: Int
    let failedAttachments: [String]

    nonisolated init(text: String, pageCount: Int, attachmentCount: Int = 0, failedAttachments: [String] = []) {
        self.text = text
        self.pageCount = pageCount
        self.attachmentCount = attachmentCount
        self.failedAttachments = failedAttachments
    }
}

struct TextRecognitionService {
    func recognize(url: URL, contentTypeIdentifier: String) async throws -> RecognitionResult {
        try await Task.detached(priority: .userInitiated) {
            guard let type = UTType(contentTypeIdentifier) else {
                throw TextRecognitionError.unsupportedType
            }

            if type.conforms(to: .pdf) {
                return try recognizePDF(at: url)
            }
            if type.conforms(to: .image) {
                return try recognizeImage(at: url)
            }
            if type.conforms(to: .emailMessage) || url.pathExtension.lowercased() == "eml" {
                let message = try EmailMessageService().parse(url: url)
                var sections = [message.text]
                var pageCount = 1
                var failedAttachments: [String] = []
                for attachment in message.attachments {
                    let ext = URL(fileURLWithPath: attachment.filename).pathExtension.lowercased()
                    do {
                        let result: RecognitionResult
                        if ext == "pdf" {
                            result = try recognizePDF(data: attachment.data)
                        } else {
                            result = try OfficeDocumentService().recognize(
                                data: attachment.data,
                                filenameExtension: ext
                            )
                        }
                        sections.append("Anhang: \(attachment.filename)\n\n\(result.text)")
                        pageCount += result.pageCount
                    } catch {
                        failedAttachments.append("\(attachment.filename): \(error.localizedDescription)")
                        sections.append("Anhang: \(attachment.filename) (konnte nicht gelesen werden)")
                    }
                }
                return RecognitionResult(
                    text: sections.joined(separator: "\n\n"),
                    pageCount: pageCount,
                    attachmentCount: message.attachments.count,
                    failedAttachments: failedAttachments
                )
            }
            if DocumentStore.officeTypes.contains(where: { type.conforms(to: $0) }) {
                return try OfficeDocumentService().recognize(url: url)
            }
            throw TextRecognitionError.unsupportedType
        }.value
    }
}

private nonisolated func recognizePDF(at url: URL) throws -> RecognitionResult {
    guard let document = PDFDocument(url: url) else {
        throw TextRecognitionError.cannotOpenDocument
    }

    return try recognizePDF(document: document)
}

private nonisolated func recognizePDF(data: Data) throws -> RecognitionResult {
    guard let document = PDFDocument(data: data) else {
        throw TextRecognitionError.cannotOpenDocument
    }

    return try recognizePDF(document: document)
}

private nonisolated func recognizePDF(document: PDFDocument) throws -> RecognitionResult {

    var pages: [String] = []
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index), let image = render(page: page) else {
            throw TextRecognitionError.cannotRenderPage(index + 1)
        }
        pages.append(try recognizeText(in: image))
    }

    return RecognitionResult(text: pages.joined(separator: "\n\n"), pageCount: document.pageCount)
}

private nonisolated func recognizeImage(at url: URL) throws -> RecognitionResult {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw TextRecognitionError.cannotOpenDocument
    }
    return RecognitionResult(text: try recognizeText(in: image), pageCount: 1)
}

private nonisolated func recognizeText(in image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["de-DE", "en-US"]

    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])

    return (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n")
}

private nonisolated func render(page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    let maximumDimension: CGFloat = 2400
    let scale = min(maximumDimension / max(bounds.width, bounds.height), 3)
    let width = max(1, Int(bounds.width * scale))
    let height = max(1, Int(bounds.height * scale))
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
}
