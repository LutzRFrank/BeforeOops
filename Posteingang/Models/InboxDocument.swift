import Foundation
import SwiftData

enum DocumentStatus: String, Codable, CaseIterable {
    case new
    case processing
    case ready
    case reviewed
    case noAction
    case failed

    var title: String {
        switch self {
        case .new: "Neu"
        case .processing: "Wird verarbeitet"
        case .ready: "Bereit zur Prüfung"
        case .reviewed: "Geprüft"
        case .noAction: "Keine Handlung"
        case .failed: "Fehlgeschlagen"
        }
    }
}

@Model
final class InboxDocument {
    var id: UUID = UUID()
    var title: String = ""
    var importedAt: Date = Date.now
    var statusRawValue: String = DocumentStatus.new.rawValue
    var originalFilename: String = ""
    var storedFilename: String = ""
    var contentTypeIdentifier: String = ""
    var pageCount: Int = 1
    var fileSize: Int64 = 0
    @Attribute(.externalStorage) var originalData: Data?
    var recognizedText: String = ""
    var recognizedAt: Date?
    var processingError: String?
    var analyzedDocumentType: String?
    var analysisSummary: String?
    var recommendedAction: String?
    var actionableDateText: String?
    var actionableDateMeaning: String?
    var analysisUsedAppleIntelligence: Bool = false
    var analysisVersion: Int = 0
    var manualSortIndex: Int?
    var syncRequestedAt: Date?
    var reminderCreatedAt: Date?
    var reminderDueDate: Date?
    var completedAt: Date?
    var deletedAt: Date?

    var status: DocumentStatus {
        get { DocumentStatus(rawValue: statusRawValue) ?? .new }
        set { statusRawValue = newValue.rawValue }
    }

    func replaceGeneratedScanTitle(with documentType: String) {
        let prefix = "Scan-"
        guard title.hasPrefix(prefix),
              UUID(uuidString: String(title.dropFirst(prefix.count))) != nil
        else { return }

        title = documentType == "Dokument" ? "Gescanntes Dokument" : documentType
    }

    init(
        id: UUID = UUID(),
        title: String,
        importedAt: Date = .now,
        status: DocumentStatus = .new,
        originalFilename: String,
        storedFilename: String,
        contentTypeIdentifier: String,
        pageCount: Int = 1,
        fileSize: Int64,
        originalData: Data? = nil,
        recognizedText: String = "",
        recognizedAt: Date? = nil,
        processingError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.importedAt = importedAt
        self.statusRawValue = status.rawValue
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.pageCount = pageCount
        self.fileSize = fileSize
        self.originalData = originalData
        self.recognizedText = recognizedText
        self.recognizedAt = recognizedAt
        self.processingError = processingError
    }
}
