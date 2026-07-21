import Foundation
import UniformTypeIdentifiers

enum DocumentStoreError: LocalizedError {
    case unsupportedType
    case unreadableFile
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Dieses Dateiformat wird noch nicht unterstützt."
        case .unreadableFile: "Die Datei konnte nicht gelesen werden."
        case .emptyFile: "Die ausgewählte Datei enthält keine lesbaren Daten."
        }
    }
}

struct ImportedDocument {
    let title: String
    let originalFilename: String
    let storedFilename: String
    let contentTypeIdentifier: String
    let fileSize: Int64
    let originalData: Data
}

struct DocumentStore {
    static let appGroupIdentifier = "group.de.lutzfrank.posteingang"
    nonisolated static let officeTypes = ["doc", "docx", "xls", "xlsx", "ppt", "pptx"]
        .compactMap { UTType(filenameExtension: $0) }
    private let fileManager = FileManager.default

    func pendingSharedFiles() throws -> [URL] {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else { return [] }
        let directory = container.appendingPathComponent("PendingImports", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ).sorted {
            let first = try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
            let second = try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate
            return (first ?? .distantPast) < (second ?? .distantPast)
        }
    }

    func removePendingSharedFile(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func removeOrphanedOriginals(keeping filenames: Set<String>) throws {
        let directory = try documentsDirectory
        for url in try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where !filenames.contains(url.lastPathComponent) {
            try fileManager.removeItem(at: url)
        }
    }

    private var documentsDirectory: URL {
        get throws {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support.appending(path: "Originals", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var protectedDirectory = directory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(resourceValues)
            return directory
        }
    }

    func importFile(from sourceURL: URL) throws -> ImportedDocument {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let type = supportedType(for: sourceURL) else {
            throw DocumentStoreError.unsupportedType
        }

        let filenameExtension = preferredFilenameExtension(for: type, sourceURL: sourceURL)
        let storedFilename = UUID().uuidString + "." + filenameExtension
        let destination = try documentsDirectory.appending(path: storedFilename)
        try copyCoordinated(from: sourceURL, to: destination)

        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else {
            try? fileManager.removeItem(at: destination)
            throw DocumentStoreError.emptyFile
        }

        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
        #endif

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        var protectedDestination = destination
        var destinationValues = URLResourceValues()
        destinationValues.isExcludedFromBackup = true
        try protectedDestination.setResourceValues(destinationValues)

        return ImportedDocument(
            title: displayName(for: sourceURL).deletingPathExtension().lastPathComponent,
            originalFilename: displayName(for: sourceURL).lastPathComponent,
            storedFilename: storedFilename,
            contentTypeIdentifier: type.identifier,
            fileSize: Int64(fileSize),
            originalData: try Data(contentsOf: destination, options: .mappedIfSafe)
        )
    }

    private func displayName(for url: URL) -> URL {
        let filename = url.lastPathComponent
        guard let separator = filename.range(of: "--") else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(String(filename[separator.upperBound...]))
    }

    func url(for document: InboxDocument) throws -> URL {
        let destination = try documentsDirectory.appending(path: document.storedFilename)
        if !fileManager.fileExists(atPath: destination.path), let data = document.originalData {
            try data.write(to: destination, options: .atomic)
            try protectFile(at: destination)
        }
        guard fileManager.fileExists(atPath: destination.path) else {
            throw DocumentStoreError.unreadableFile
        }
        return destination
    }

    func data(for document: InboxDocument) throws -> Data {
        if let data = document.originalData { return data }
        return try Data(contentsOf: url(for: document), options: .mappedIfSafe)
    }

    func deleteFile(for document: InboxDocument) throws {
        let url = try url(for: document)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func supportedType(for url: URL) -> UTType? {
        let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let extensionType = UTType(filenameExtension: url.pathExtension)

        if isEmail(url: url, types: [resourceType, extensionType].compactMap { $0 })
            || looksLikeEmail(at: url) {
            return .emailMessage
        }

        return [resourceType, extensionType]
            .compactMap { $0 }
            .first { candidate in
                candidate.conforms(to: .pdf)
                    || candidate.conforms(to: .image)
                    || Self.officeTypes.contains(where: { officeType in candidate.conforms(to: officeType) })
            }
    }

    private func isEmail(url: URL, types: [UTType]) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        if extensionName == "eml" || extensionName == "emlx" { return true }
        return types.contains { type in
            type.conforms(to: .emailMessage)
                || type.identifier.localizedCaseInsensitiveContains("email")
                || type.identifier.localizedCaseInsensitiveContains("mail.message")
                || type.identifier.localizedCaseInsensitiveContains("rfc822")
        }
    }

    private func looksLikeEmail(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let prefix = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return false }

        let normalized = prefix.replacingOccurrences(of: "\r\n", with: "\n")
        let headerBlock = normalized.components(separatedBy: "\n\n").first ?? normalized
        let headerNames = headerBlock.components(separatedBy: "\n").compactMap { line -> String? in
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let separator = line.firstIndex(of: ":") else { return nil }
            return String(line[..<separator]).lowercased()
        }
        let headers = Set(headerNames)
        return headers.contains("from")
            && headers.contains("subject")
            && (headers.contains("date") || headers.contains("message-id") || headers.contains("mime-version"))
    }

    private func preferredFilenameExtension(for type: UTType, sourceURL: URL) -> String {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        if !sourceExtension.isEmpty { return sourceExtension }
        if type.conforms(to: .emailMessage) { return "eml" }
        return type.preferredFilenameExtension ?? (type.conforms(to: .pdf) ? "pdf" : "img")
    }

    private func copyCoordinated(from sourceURL: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { readableURL in
            do {
                try fileManager.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }

        if let copyError { throw copyError }
        if let coordinationError { throw coordinationError }
        guard fileManager.fileExists(atPath: destination.path) else {
            throw DocumentStoreError.unreadableFile
        }
    }

    private func protectFile(at destination: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
        #endif
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        var protectedDestination = destination
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDestination.setResourceValues(values)
    }
}
