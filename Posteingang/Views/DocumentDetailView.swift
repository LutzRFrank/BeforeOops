import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PDFKit
import QuickLookThumbnailing

#if os(iOS)
import QuickLook
#elseif os(macOS)
import QuickLookUI
#endif

struct DocumentDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let document: InboxDocument
    let onRemove: () -> Void

    @State private var previewURL: URL?
    @State private var previewItems: [DocumentPreviewItem] = []
    @State private var selectedPreviewItemID: String?
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var reminderMessage: String?
    @State private var reminderWasCreated = false
    @State private var isConfirmingRemoval = false
    @State private var isAnalyzing = false
    @State private var landscapePreviewRatio: CGFloat = 0.42
    @State private var landscapeAnalysisRatio: CGFloat = 0.25
    @State private var previewDragStart: CGFloat?
    @State private var analysisDragStart: CGFloat?
    @State private var macLoadedPreviewItemIDs: Set<String> = []
    @AppStorage("reminderLeadDays") private var reminderLeadDays = ReminderLeadTime.oneWeek.rawValue

    var body: some View {
        documentLayout
            .navigationTitle(document.title)
            .toolbar {
                if let exportURL {
                    ToolbarItem(placement: .secondaryAction) {
                        ShareLink(item: exportURL) {
                            Label("Exportieren", systemImage: "square.and.arrow.up")
                        }
                        .help("Original mit Intelligence-Analyse exportieren")
                    }
                }
            }
            .task(id: document.id) {
                do {
                    try preparePreview()
                    await refreshAnalysisIfNeeded()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .task(id: exportFingerprint) {
                guard let previewURL else { return }
                do {
                    exportURL = try DocumentExportService().makeIntelligentPDF(
                        for: document,
                        originalURL: previewURL
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Erinnerung", isPresented: Binding(
                get: { reminderMessage != nil },
                set: { if !$0 { reminderMessage = nil } }
            )) {
                if reminderWasCreated {
                    Button("Eintrag aus BeforeOops entfernen", role: .destructive) {
                        reminderMessage = nil
                        removeFromBeforeOops()
                    }
                    Button("Eintrag behalten", role: .cancel) {
                        reminderMessage = nil
                        markCompleted()
                    }
                } else {
                    Button("OK", role: .cancel) { reminderMessage = nil }
                }
            } message: {
                Text(reminderMessage ?? "")
            }
            .confirmationDialog(
                "Eintrag aus BeforeOops entfernen?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Eintrag entfernen", role: .destructive) {
                    removeFromBeforeOops()
                }
                Button("Als erledigt behalten") {
                    markCompleted()
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die ursprünglich importierte Datei im Finder oder in Mail bleibt unverändert.")
            }
    }

    @ViewBuilder
    private var documentLayout: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            if previewItems.count > 1 {
                previewSidebar
                    .frame(width: 170)
                Divider()
            }
            VSplitView {
                previewPanel
                    .frame(minHeight: 180)
                if let summary = document.analysisSummary {
                    intelligentAnalysisCard(summary: summary)
                        .frame(minHeight: 155, idealHeight: 190)
                }
                recognitionPanel
                    .frame(minHeight: 160)
            }
        }
        #else
        GeometryReader { geometry in
            resizableDocumentLayout(height: geometry.size.height)
        }
        #endif
    }

    #if os(iOS)
    private func resizableDocumentLayout(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            previewSection
                .frame(height: max(100, height * landscapePreviewRatio))

            resizeDivider {
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if previewDragStart == nil { previewDragStart = landscapePreviewRatio }
                        let start = previewDragStart ?? landscapePreviewRatio
                        let maximum = document.analysisSummary == nil
                            ? 0.78
                            : max(0.24, 0.76 - landscapeAnalysisRatio)
                        landscapePreviewRatio = min(max(start + value.translation.height / height, 0.18), maximum)
                    }
                    .onEnded { _ in previewDragStart = nil }
            }

            if let summary = document.analysisSummary {
                intelligentAnalysisCard(summary: summary)
                    .frame(height: max(100, height * landscapeAnalysisRatio))
                    .clipped()

                resizeDivider {
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if analysisDragStart == nil { analysisDragStart = landscapeAnalysisRatio }
                            let start = analysisDragStart ?? landscapeAnalysisRatio
                            let maximum = max(0.20, 0.78 - landscapePreviewRatio)
                            landscapeAnalysisRatio = min(max(start + value.translation.height / height, 0.16), maximum)
                        }
                        .onEnded { _ in analysisDragStart = nil }
                }
            }

            recognitionPanel
                .frame(maxHeight: .infinity)
        }
    }

    private func resizeDivider<G: Gesture>(gesture: () -> G) -> some View {
        ZStack {
            Color.clear
            Divider()
            Capsule()
                .fill(.secondary.opacity(0.55))
                .frame(width: 38, height: 4)
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .zIndex(10)
        .highPriorityGesture(gesture())
        .accessibilityLabel("Bereichsgröße ändern")
    }
    #endif

    #if os(iOS)
    private var previewSection: some View {
        VStack(spacing: 0) {
            if previewItems.count > 1 {
                previewStrip
                Divider()
            }
            previewPanel
        }
    }

    private var previewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(previewItems) { item in
                    previewItemButton(item, compact: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(height: 82)
        .background(.bar)
    }
    #endif

    #if os(macOS)
    private var previewSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(previewItems) { item in
                    previewItemButton(item, compact: false)
                }
            }
            .padding(8)
        }
        .background(.bar)
    }
    #endif

    private func previewItemButton(_ item: DocumentPreviewItem, compact: Bool) -> some View {
        Button {
            #if os(macOS)
            if case .file = item.content {
                macLoadedPreviewItemIDs.insert(item.id)
            }
            #endif
            selectedPreviewItemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                previewThumbnail(for: item)
                    .frame(width: compact ? 54 : 142, height: compact ? 42 : 92)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(item.title)
                    .font(.caption)
                    .lineLimit(2)
            }
            .padding(6)
            .frame(width: compact ? 72 : 154, alignment: .leading)
            .background(
                selectedPreviewItemID == item.id ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func previewThumbnail(for item: DocumentPreviewItem) -> some View {
        switch item.content {
        case .email:
            ZStack {
                Color.secondary.opacity(0.10)
                Image(systemName: "envelope.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        case .file(let url):
            DocumentThumbnail(url: url)
        }
    }

    @ViewBuilder
    private var previewPanel: some View {
        if let item = selectedPreviewItem {
            switch item.content {
            case .email(let text):
                emailPreviewPanel(text: text)
            case .file(let url):
                #if os(macOS)
                macOSFilePreviewStack
                #else
                QuickLookPreview(url: url)
                    .id(url)
                #endif
            }
        } else if let previewURL {
            #if os(macOS)
            if isModernOfficeDocument(previewURL) {
                MacOfficePlaceholder(url: previewURL)
            } else {
                QuickLookPreview(url: previewURL)
            }
            #else
            QuickLookPreview(url: previewURL)
            #endif
        } else if let errorMessage {
            ContentUnavailableView(
                "Dokument nicht verfügbar",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else {
            ProgressView("Dokument wird geöffnet …")
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var macOSFilePreviewStack: some View {
        ZStack {
            ForEach(previewItems.filter { macLoadedPreviewItemIDs.contains($0.id) }) { item in
                if case .file(let url) = item.content {
                    Group {
                        if isModernOfficeDocument(url) {
                            MacOfficePlaceholder(url: url)
                        } else {
                            QuickLookPreview(url: url)
                        }
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(selectedPreviewItemID == item.id ? 1 : 0)
                        .allowsHitTesting(selectedPreviewItemID == item.id)
                        .accessibilityHidden(selectedPreviewItemID != item.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isModernOfficeDocument(_ url: URL) -> Bool {
        ["docx", "xlsx", "pptx"].contains(url.pathExtension.lowercased())
    }
    #endif

    private func emailPreviewPanel(text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("E-Mail", systemImage: "envelope")
                .font(.headline)
            ScrollView {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func intelligentAnalysisCard(summary: String) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        document.analyzedDocumentType ?? "Dokumentanalyse",
                        systemImage: "sparkles"
                    )
                    .font(.headline)
                    Spacer()
                    Text(document.analysisUsedAppleIntelligence ? "On-Device Intelligence" : "Lokale Analyse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isAnalyzing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
                if let meaning = document.actionableDateMeaning,
                   let dateText = document.actionableDateText,
                   !meaning.isEmpty, !dateText.isEmpty {
                    Label("\(meaning): \(dateText)", systemImage: "calendar")
                        .foregroundStyle(.secondary)
                }
                if let action = document.recommendedAction, !action.isEmpty {
                    Label(action, systemImage: "arrow.right.circle")
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    completedButton
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var completedButton: some View {
        if document.completedAt != nil || document.reminderCreatedAt != nil {
            Button("Erledigt", systemImage: "checkmark.circle.fill") {
                isConfirmingRemoval = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .help("Erinnerung angelegt – Eintrag aus BeforeOops entfernen")
        } else {
            Button("Erledigt", systemImage: "checkmark.circle") {
                isConfirmingRemoval = true
            }
            .help("Eintrag aus BeforeOops entfernen")
        }
    }

    private var recognitionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Erkannter Text", systemImage: "text.viewfinder")
                    .font(.headline)
                Spacer()
                if document.status == .processing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Erneut erkennen", systemImage: "arrow.clockwise") {
                        Task { await recognizeText() }
                    }
                }
            }

            if let message = document.processingError {
                ContentUnavailableView(
                    "Texterkennung fehlgeschlagen",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            } else if document.status == .processing {
                ProgressView("Text wird lokal erkannt …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if document.recognizedText.isEmpty {
                ContentUnavailableView(
                    "Kein Text erkannt",
                    systemImage: "text.magnifyingglass"
                )
            } else {
                ScrollView {
                    Text(document.recognizedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !detectedDates.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Erkannte Termine", systemImage: "calendar.badge.exclamationmark")
                        .font(.headline)
                    ForEach(detectedDates) { detectedDate in
                        detectedDateButton(for: detectedDate)
                    }
                }
            }
        }
        .padding()
    }

    private var detectedDates: [DetectedDate] {
        DetectedDateService().dates(in: document.recognizedText)
    }

    @ViewBuilder
    private func detectedDateButton(for detectedDate: DetectedDate) -> some View {
        let title = detectedDate.date.formatted(
            .dateTime.locale(Locale(identifier: "de_DE")).day().month().year()
        )
        if hasReminder(for: detectedDate.date) {
            Label(title, systemImage: "checkmark.circle.fill")
                .fontWeight(.medium)
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .help("Erinnerung wurde angelegt")
        } else {
            Button {
                Task { await createReminder(for: detectedDate) }
            } label: {
                Label(title, systemImage: "bell.badge")
            }
            .help("Erinnerung eine Woche vorher erstellen")
        }
    }

    private func hasReminder(for date: Date) -> Bool {
        if let reminderDueDate = document.reminderDueDate {
            return Calendar.autoupdatingCurrent.isDate(reminderDueDate, inSameDayAs: date)
        }
        return document.reminderCreatedAt != nil && detectedDates.count == 1
    }

    private var exportFingerprint: String {
        [
            previewURL?.path ?? "",
            document.analyzedDocumentType ?? "",
            document.analysisSummary ?? "",
            document.actionableDateMeaning ?? "",
            document.actionableDateText ?? "",
            document.recommendedAction ?? "",
            String(document.analysisVersion)
        ].joined(separator: "|")
    }

    private func preparePreview() throws {
        let store = DocumentStore()
        let originalURL = try store.url(for: document)
        previewItems = []
        selectedPreviewItemID = nil
        guard isEmailDocument else {
            previewURL = originalURL
            return
        }

        let data = try store.data(for: document)
        let message = try EmailMessageService().parse(data: data)
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Previews", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        var items = [DocumentPreviewItem(id: "email", title: "E-Mail", content: .email(message.text))]
        var firstAttachmentURL: URL?
        for (index, attachment) in message.attachments.enumerated() {
            let safeFilename = URL(fileURLWithPath: attachment.filename).lastPathComponent
            let url = cacheDirectory.appending(path: "\(document.id.uuidString)-\(index)-\(safeFilename)")
            try attachment.data.write(to: url, options: .atomic)
            if firstAttachmentURL == nil { firstAttachmentURL = url }
            items.append(DocumentPreviewItem(
                id: "pdf-\(index)",
                title: safeFilename,
                content: .file(url)
            ))
        }
        previewItems = items
        selectedPreviewItemID = items.first?.id
        if let firstAttachmentURL {
            previewURL = firstAttachmentURL
            return
        }

        let url = cacheDirectory.appending(path: "\(document.id.uuidString).eml")
        try data.write(to: url, options: .atomic)
        previewURL = url
    }

    private var selectedPreviewItem: DocumentPreviewItem? {
        guard let selectedPreviewItemID else { return previewItems.first }
        return previewItems.first { $0.id == selectedPreviewItemID }
    }

    private var isEmailDocument: Bool {
        if document.originalFilename.lowercased().hasSuffix(".eml")
            || document.originalFilename.lowercased().hasSuffix(".emlx") { return true }
        guard let type = UTType(document.contentTypeIdentifier) else { return false }
        return type.conforms(to: .emailMessage)
            || type.identifier.localizedCaseInsensitiveContains("email")
            || type.identifier.localizedCaseInsensitiveContains("mail.message")
    }

    private func createReminder(for detectedDate: DetectedDate) async {
        do {
            try await ReminderService().create(
                title: document.title,
                dueDate: detectedDate.date,
                notes: "Erkannt in: \(document.originalFilename)\nDatumsangabe: \(detectedDate.sourceText)",
                leadDays: reminderLeadDays
            )
            reminderWasCreated = true
            document.reminderCreatedAt = .now
            document.reminderDueDate = detectedDate.date
            document.completedAt = .now
            document.status = .reviewed
            try? modelContext.save()
            let leadTitle = ReminderLeadTime(rawValue: reminderLeadDays)?.title ?? "\(reminderLeadDays) Tage vorher"
            reminderMessage = "Erinnerung für \(detectedDate.date.formatted(date: .long, time: .omitted)) erstellt – Hinweis \(leadTitle.lowercased())."
        } catch {
            reminderWasCreated = false
            reminderMessage = error.localizedDescription
        }
    }

    private func removeFromBeforeOops() {
        onRemove()
    }

    private func markCompleted() {
        document.completedAt = .now
        document.status = .reviewed
        try? modelContext.save()
    }

    private func refreshAnalysisIfNeeded() async {
        guard !document.recognizedText.isEmpty,
              document.analysisVersion != IntelligentDocumentService.currentAnalysisVersion,
              !isAnalyzing
        else { return }

        isAnalyzing = true
        let analysis = await IntelligentDocumentService().analyze(
            title: document.title,
            text: document.recognizedText
        )
        document.replaceGeneratedScanTitle(with: analysis.documentType)
        document.analyzedDocumentType = analysis.documentType
        document.analysisSummary = analysis.summary
        document.recommendedAction = analysis.recommendedAction
        document.actionableDateText = analysis.actionableDateText
        document.actionableDateMeaning = analysis.actionableDateMeaning
        document.analysisUsedAppleIntelligence = analysis.usedAppleIntelligence
        document.analysisVersion = IntelligentDocumentService.currentAnalysisVersion
        try? modelContext.save()
        isAnalyzing = false
    }

    private func recognizeText() async {
        document.status = .processing
        document.processingError = nil
        do {
            let url = try DocumentStore().url(for: document)
            let previousText = document.recognizedText
            let result = try await TextRecognitionService().recognize(
                url: url,
                contentTypeIdentifier: document.contentTypeIdentifier
            )
            document.recognizedText = result.text
            document.pageCount = result.pageCount
            document.recognizedAt = .now
            document.status = .ready
            if previousText != result.text
                || document.analysisSummary == nil
                || document.analysisVersion != IntelligentDocumentService.currentAnalysisVersion {
                let analysis = await IntelligentDocumentService().analyze(
                    title: document.title,
                    text: result.text
                )
                document.replaceGeneratedScanTitle(with: analysis.documentType)
                document.analyzedDocumentType = analysis.documentType
                document.analysisSummary = analysis.summary
                document.recommendedAction = analysis.recommendedAction
                document.actionableDateText = analysis.actionableDateText
                document.actionableDateMeaning = analysis.actionableDateMeaning
                document.analysisUsedAppleIntelligence = analysis.usedAppleIntelligence
                document.analysisVersion = IntelligentDocumentService.currentAnalysisVersion
            }
            try modelContext.save()
        } catch {
            document.processingError = error.localizedDescription
            document.status = .failed
        }
    }
}

private struct DocumentPreviewItem: Identifiable {
    enum Content {
        case email(String)
        case file(URL)
    }

    let id: String
    let title: String
    let content: Content
}

private struct DocumentThumbnail: View {
    let url: URL
    @State private var thumbnail: PlatformImage?

    var body: some View {
        Group {
            if let thumbnail {
            #if os(iOS)
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
            #else
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
            #endif
            } else {
                ZStack {
                    Color.secondary.opacity(0.10)
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 300, height: 220),
                scale: 2,
                representationTypes: .thumbnail
            )
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).platformImage
        }
    }
}

#if os(iOS)
private typealias PlatformImage = UIImage
private extension QLThumbnailRepresentation { var platformImage: UIImage { uiImage } }
#else
private typealias PlatformImage = NSImage
private extension QLThumbnailRepresentation { var platformImage: NSImage { nsImage } }
#endif

#if os(iOS)
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
        controller.refreshCurrentPreviewItem()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#elseif os(macOS)
private struct MacOfficePlaceholder: View {
    let url: URL

    var body: some View {
        ContentUnavailableView {
            Label("Keine Office-Vorschau auf dem Mac", systemImage: "doc.badge.ellipsis")
        } description: {
            Text("Apple stellt für dieses Office-Dokument keine vollständige macOS-Vorschau bereit.")
        } actions: {
            Button("In \(applicationName) öffnen", systemImage: "arrow.up.forward.app") {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var applicationName: String {
        switch url.pathExtension.lowercased() {
        case "docx": "Word"
        case "xlsx": "Excel"
        case "pptx": "PowerPoint"
        default: "Office"
        }
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.previewItem = url as NSURL
        return view
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: QLPreviewView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if let currentURL = view.previewItem as? URL, currentURL == url { return }
        if let currentURL = view.previewItem as? NSURL, currentURL as URL == url { return }
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }
}
#endif
