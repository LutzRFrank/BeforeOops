import UniformTypeIdentifiers

#if os(iOS)
import UIKit
typealias PlatformViewController = UIViewController
#elseif os(macOS)
import AppKit
typealias PlatformViewController = NSViewController
#endif

final class ShareViewController: PlatformViewController {
    private let officeTypes = ["doc", "docx", "xls", "xlsx", "ppt", "pptx"]
        .compactMap { UTType(filenameExtension: $0) }
    #if os(iOS)
    private let statusLabel = UILabel()
    #elseif os(macOS)
    private let statusLabel = NSTextField(labelWithString: "")
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        #if os(iOS)
        view.backgroundColor = .systemBackground
        #elseif os(macOS)
        preferredContentSize = NSSize(width: 420, height: 180)
        #endif
        #if os(iOS)
        statusLabel.text = "Wird an BeforeOops übergeben …"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        #elseif os(macOS)
        statusLabel.stringValue = "Wird an BeforeOops übergeben …"
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        #endif
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        Task { await receiveItems() }
    }

    private func receiveItems() async {
        do {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.de.lutzfrank.posteingang"
            ) else { throw ShareError.unavailableContainer }
            let inbox = container.appendingPathComponent("PendingImports", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

            let providers = extensionContext?.inputItems
                .compactMap { $0 as? NSExtensionItem }
                .compactMap(\.attachments)
                .flatMap { $0 } ?? []
            var imported = 0
            for provider in providers {
                guard let type = provider.registeredContentTypes.first(where: { candidate in
                    candidate.conforms(to: .pdf)
                        || candidate.conforms(to: .image)
                        || officeTypes.contains(where: { officeType in candidate.conforms(to: officeType) })
                }) else { continue }
                try await copyRepresentation(from: provider, type: type, to: inbox)
                imported += 1
            }
            guard imported > 0 else { throw ShareError.noSupportedItems }
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            #if os(iOS)
            statusLabel.text = error.localizedDescription
            #elseif os(macOS)
            statusLabel.stringValue = error.localizedDescription
            #endif
        }
    }

    private func copyRepresentation(
        from provider: NSItemProvider,
        type: UTType,
        to directory: URL
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type) { source, _, error in
                do {
                    if let error { throw error }
                    guard let source else { throw ShareError.noSupportedItems }
                    let fileExtension = source.pathExtension.isEmpty
                        ? (type.preferredFilenameExtension ?? "dat")
                        : source.pathExtension
                    let name = source.deletingPathExtension().lastPathComponent
                    let destination = directory.appendingPathComponent(
                        "\(UUID().uuidString)--\(name).\(fileExtension)"
                    )
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum ShareError: LocalizedError {
    case unavailableContainer
    case noSupportedItems

    var errorDescription: String? {
        switch self {
        case .unavailableContainer: "Der gemeinsame Dokumenteingang ist nicht verfügbar."
        case .noSupportedItems: "Keine unterstützte PDF-, Bild- oder Office-Datei gefunden."
        }
    }
}
