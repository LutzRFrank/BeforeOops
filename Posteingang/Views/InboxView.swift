import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import CloudKit

struct InboxView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var documents: [InboxDocument]

    @State private var selectedDocument: InboxDocument?
    @State private var isImporting = false
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var pendingDeletion: InboxDocument?
    @State private var syncMessage: String?
    @State private var isSyncing = false
    @State private var isDropTargeted = false
    @State private var inboxFilter: InboxFilter = .open
    @State private var isShowingSettings = false
    @State private var recentlyTrashed: InboxDocument?
    @State private var importFeedback: ImportFeedback?
    @AppStorage("hideCompletedDocuments") private var hideCompletedDocuments = true
    @AppStorage("inboxSortOrder") private var sortOrderRawValue = InboxSortOrder.manual.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        NavigationSplitView {
            Group {
                if documents.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Dokumente", systemImage: "tray")
                    } description: {
                        Text("Importiere eine E-Mail, PDF- oder Bilddatei oder scanne einen Brief.")
                    } actions: {
                        Button("Dokument importieren") { isImporting = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("Dokumentstatus", selection: $inboxFilter) {
                            ForEach(availableFilters) { filter in
                                Text(filter.title).tag(filter)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Dokumentstatus")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)

                        if filteredDocuments.isEmpty {
                            ContentUnavailableView(
                                inboxFilter.emptyTitle,
                                systemImage: inboxFilter.emptyIcon,
                                description: Text(inboxFilter.emptyDescription)
                            )
                        } else {
                            List(selection: $selectedDocument) {
                                ForEach(filteredDocuments) { document in
                                    documentRow(for: document)
                                }
                                .onMove(perform: moveDocuments)
                                .onDelete(perform: requestDeletion)
                            }
                            #if os(iOS)
                            .refreshable {
                                importPendingSharedDocuments()
                                backfillCloudAssets()
                                try? await Task.sleep(for: .milliseconds(350))
                            }
                            #endif
                        }
                    }
                }
            }
            .navigationTitle("BeforeOops")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Importieren", systemImage: "square.and.arrow.down") {
                        isImporting = true
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Scannen", systemImage: "doc.viewfinder") {
                        isScanning = true
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    EditButton()
                }
                ToolbarItem(placement: .secondaryAction) {
                    syncButton
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Einstellungen", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                }
            }
            #endif
        } detail: {
            if let selectedDocument {
                DocumentDetailView(document: selectedDocument) {
                    moveToTrash(selectedDocument)
                }
            } else {
                ContentUnavailableView("Dokument auswählen", systemImage: "doc.text.magnifyingglass")
            }
        }
        #if os(macOS)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Importieren", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                syncButton
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Einstellungen", systemImage: "gearshape") {
                    isShowingSettings = true
                }
            }
        }
        #endif
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importDocument(from: url)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 7]))
                    .padding(12)
                    .overlay {
                        Label("E-Mail, PDF oder Bild hier ablegen", systemImage: "square.and.arrow.down")
                            .font(.title2.weight(.semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 14)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if let importFeedback {
                ImportFeedbackBanner(feedback: importFeedback)
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: importFeedback.id) {
                        try? await Task.sleep(for: .seconds(5))
                        if self.importFeedback?.id == importFeedback.id {
                            withAnimation { self.importFeedback = nil }
                        }
                    }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf, .image, .emailMessage] + DocumentStore.officeTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importDocument(from: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isScanning) {
            DocumentScanner { url in
                isScanning = false
                importDocument(from: url)
            } onCancel: {
                isScanning = false
            } onError: { error in
                isScanning = false
                errorMessage = error.localizedDescription
            }
            .ignoresSafeArea()
        }
        #endif
        .alert("Import nicht möglich", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unbekannter Fehler")
        }
        .alert("iCloud-Synchronisierung", isPresented: Binding(
            get: { syncMessage != nil },
            set: { if !$0 { syncMessage = nil } }
        )) {
            Button("OK", role: .cancel) { syncMessage = nil }
        } message: {
            Text(syncMessage ?? "")
        }
        .confirmationDialog(
            inboxFilter == .trash ? "Dokument endgültig löschen?" : "Dokument in den Papierkorb bewegen?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(inboxFilter == .trash ? "Endgültig löschen" : "In den Papierkorb", role: .destructive) {
                if let document = pendingDeletion {
                    if inboxFilter == .trash {
                        permanentlyDelete(document)
                    } else {
                        moveToTrash(document)
                    }
                }
                pendingDeletion = nil
            }
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(inboxFilter == .trash
                 ? "Originaldatei, erkannter Text und Analyse werden dauerhaft entfernt."
                 : "Der Eintrag kann 30 Tage lang wiederhergestellt werden.")
        }
        .alert("In den Papierkorb bewegt", isPresented: Binding(
            get: { recentlyTrashed != nil },
            set: { if !$0 { recentlyTrashed = nil } }
        )) {
            Button("Rückgängig") {
                if let document = recentlyTrashed { restore(document) }
                recentlyTrashed = nil
            }
            Button("OK", role: .cancel) { recentlyTrashed = nil }
        }
        .sheet(isPresented: $isShowingSettings) {
            AppSettingsView()
        }
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView()
        }
        .task {
            if !hideCompletedDocuments, inboxFilter == .open { inboxFilter = .all }
            purgeExpiredTrash()
            backfillCloudAssets()
            while !Task.isCancelled {
                importPendingSharedDocuments()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                purgeExpiredTrash()
                importPendingSharedDocuments()
            }
        }
        .onChange(of: documents.map(\.id)) { _, _ in
            try? DocumentStore().removeOrphanedOriginals(
                keeping: Set(documents.map(\.storedFilename))
            )
        }
        .onChange(of: inboxFilter) { _, _ in
            selectedDocument = nil
        }
        .onChange(of: hideCompletedDocuments) { _, hideCompleted in
            if hideCompleted, inboxFilter == .all { inboxFilter = .open }
            if !hideCompleted, inboxFilter == .open { inboxFilter = .all }
        }
        .onChange(of: filteredDocuments.map(\.id)) { _, visibleIDs in
            if let selectedDocument, !visibleIDs.contains(selectedDocument.id) {
                self.selectedDocument = nil
            }
        }
    }

    private func documentRow(for document: InboxDocument) -> some View {
        DocumentRow(document: document)
            .tag(document)
            #if os(iOS)
            .swipeActions(edge: .trailing) {
                if inboxFilter == .trash {
                    Button("Endgültig löschen", systemImage: "trash", role: .destructive) {
                        pendingDeletion = document
                    }
                } else {
                    Button("Papierkorb", systemImage: "trash", role: .destructive) {
                        moveToTrash(document)
                    }
                }
            }
            .swipeActions(edge: .leading) {
                if inboxFilter == .trash {
                    Button("Wiederherstellen", systemImage: "arrow.uturn.backward") {
                        restore(document)
                    }
                    .tint(.green)
                }
            }
            #endif
            .contextMenu {
                documentContextMenu(for: document)
            }
            .moveDisabled(sortOrder != .manual || inboxFilter == .trash)
    }

    @ViewBuilder
    private func documentContextMenu(for document: InboxDocument) -> some View {
        if inboxFilter == .trash {
            Button("Wiederherstellen", systemImage: "arrow.uturn.backward") {
                restore(document)
            }
            Button("Endgültig löschen", role: .destructive) {
                pendingDeletion = document
            }
        } else {
            Button("In den Papierkorb", role: .destructive) {
                moveToTrash(document)
            }
        }
    }

    private func importDocument(from url: URL) {
        do {
            let imported = try DocumentStore().importFile(from: url)
            let document = InboxDocument(
                title: emailSubject(in: imported) ?? imported.title,
                originalFilename: imported.originalFilename,
                storedFilename: imported.storedFilename,
                contentTypeIdentifier: imported.contentTypeIdentifier,
                fileSize: imported.fileSize,
                originalData: imported.originalData
            )
            document.manualSortIndex = (documents.compactMap(\.manualSortIndex).min() ?? 0) - 1
            modelContext.insert(document)
            selectedDocument = document
            Task { await recognizeText(in: document) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPendingSharedDocuments() {
        do {
            let store = DocumentStore()
            for url in try store.pendingSharedFiles() {
                let imported = try store.importFile(from: url)
                let document = InboxDocument(
                    title: emailSubject(in: imported) ?? imported.title,
                    originalFilename: imported.originalFilename,
                    storedFilename: imported.storedFilename,
                    contentTypeIdentifier: imported.contentTypeIdentifier,
                    fileSize: imported.fileSize,
                    originalData: imported.originalData
                )
                document.manualSortIndex = (documents.compactMap(\.manualSortIndex).min() ?? 0) - 1
                modelContext.insert(document)
                try store.removePendingSharedFile(at: url)
                selectedDocument = document
                Task { await recognizeText(in: document) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func backfillCloudAssets() {
        let store = DocumentStore()
        var changed = false
        for document in documents where document.originalData == nil {
            if let data = try? store.data(for: document) {
                document.originalData = data
                changed = true
            }
        }
        if changed { try? modelContext.save() }
    }

    private func emailSubject(in imported: ImportedDocument) -> String? {
        guard let type = UTType(imported.contentTypeIdentifier), type.conforms(to: .emailMessage) else {
            return nil
        }
        return try? EmailMessageService().parse(data: imported.originalData).subject
    }

    private var syncButton: some View {
        Button {
            Task { await requestCloudSync() }
        } label: {
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("iCloud synchronisieren", systemImage: "icloud.and.arrow.up")
            }
        }
        .disabled(isSyncing)
        .help("Dokumente mit iCloud synchronisieren")
    }

    private func requestCloudSync() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let status = try await CKContainer(
                identifier: "iCloud.de.lutzfrank.posteingang"
            ).accountStatus()
            guard status == .available else {
                syncMessage = "iCloud ist auf diesem Gerät nicht verfügbar. Bitte iCloud Drive und den Apple-Account in den Systemeinstellungen prüfen."
                return
            }
            backfillCloudAssets()
            let requestDate = Date.now
            for document in documents {
                document.syncRequestedAt = requestDate
            }
            try modelContext.save()
            syncMessage = "Die Synchronisierung wurde angestoßen. CloudKit überträgt Änderungen anschließend automatisch im Hintergrund."
        } catch {
            syncMessage = "iCloud konnte nicht gestartet werden: \(error.localizedDescription)"
        }
    }

    private func recognizeText(in document: InboxDocument) async {
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
                apply(analysis, to: document)
            }
            try modelContext.save()
            let deadlineCount = DetectedDateService().dates(in: result.text).count
            importFeedback = ImportFeedback(
                attachmentCount: result.attachmentCount,
                deadlineCount: deadlineCount,
                failedAttachments: result.failedAttachments
            )
        } catch {
            let detailedError = "\(document.originalFilename): \(error.localizedDescription)"
            document.processingError = detailedError
            document.status = .failed
            importFeedback = ImportFeedback(errorMessage: detailedError)
        }
    }

    private func apply(_ analysis: DocumentAnalysisResult, to document: InboxDocument) {
        document.replaceGeneratedScanTitle(with: analysis.documentType)
        document.analyzedDocumentType = analysis.documentType
        document.analysisSummary = analysis.summary
        document.recommendedAction = analysis.recommendedAction
        document.actionableDateText = analysis.actionableDateText
        document.actionableDateMeaning = analysis.actionableDateMeaning
        document.analysisUsedAppleIntelligence = analysis.usedAppleIntelligence
        document.analysisVersion = IntelligentDocumentService.currentAnalysisVersion
    }

    private func moveToTrash(_ document: InboxDocument) {
        if selectedDocument == document { selectedDocument = nil }
        document.deletedAt = .now
        recentlyTrashed = document
        try? modelContext.save()
    }

    private func restore(_ document: InboxDocument) {
        document.deletedAt = nil
        try? modelContext.save()
    }

    private func permanentlyDelete(_ document: InboxDocument) {
        let wasSelected = selectedDocument == document
        if wasSelected { selectedDocument = nil }

        Task { @MainActor in
            if wasSelected { await Task.yield() }
            do {
                try DocumentStore().deleteFile(for: document)
                modelContext.delete(document)
                try modelContext.save()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func purgeExpiredTrash() {
        guard let cutoff = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -30, to: .now) else { return }
        let expired = documents.filter { ($0.deletedAt ?? .distantFuture) < cutoff }
        guard !expired.isEmpty else { return }
        for document in expired {
            try? DocumentStore().deleteFile(for: document)
            modelContext.delete(document)
        }
        try? modelContext.save()
    }

    private var sortedDocuments: [InboxDocument] {
        documents.sorted { first, second in
            switch sortOrder {
            case .newest:
                return first.importedAt > second.importedAt
            case .oldest:
                return first.importedAt < second.importedAt
            case .title:
                return first.title.localizedStandardCompare(second.title) == .orderedAscending
            case .manual:
                break
            }
            switch (first.manualSortIndex, second.manualSortIndex) {
            case let (firstIndex?, secondIndex?):
                if firstIndex != secondIndex { return firstIndex < secondIndex }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            return first.importedAt > second.importedAt
        }
    }

    private var filteredDocuments: [InboxDocument] {
        sortedDocuments.filter { document in
            if inboxFilter == .trash { return document.deletedAt != nil }
            guard document.deletedAt == nil else { return false }
            let isCompleted = document.completedAt != nil
                || document.reminderCreatedAt != nil
                || document.status == .reviewed
            switch inboxFilter {
            case .all: return true
            case .open: return !isCompleted
            case .completed: return isCompleted
            case .trash: return false
            }
        }
    }

    private var availableFilters: [InboxFilter] {
        hideCompletedDocuments ? [.open, .completed, .trash] : [.all, .open, .completed, .trash]
    }

    private var sortOrder: InboxSortOrder {
        InboxSortOrder(rawValue: sortOrderRawValue) ?? .manual
    }

    private func moveDocuments(from source: IndexSet, to destination: Int) {
        guard sortOrder == .manual, inboxFilter != .trash else { return }
        var reorderedDocuments = filteredDocuments
        reorderedDocuments.move(fromOffsets: source, toOffset: destination)
        for (index, document) in reorderedDocuments.enumerated() {
            document.manualSortIndex = index
        }
        try? modelContext.save()
    }

    private func requestDeletion(at offsets: IndexSet) {
        guard let index = offsets.first, filteredDocuments.indices.contains(index) else { return }
        pendingDeletion = filteredDocuments[index]
    }
}

private enum InboxFilter: String, CaseIterable, Identifiable {
    case all
    case open
    case completed
    case trash

    var id: Self { self }
    var title: String {
        switch self {
        case .all: "Alle"
        case .open: "Offen"
        case .completed: "Erledigt"
        case .trash: "Papierkorb"
        }
    }
    var emptyTitle: String {
        switch self {
        case .all: "Keine Dokumente"
        case .open: "Keine offenen Dokumente"
        case .completed: "Keine erledigten Dokumente"
        case .trash: "Papierkorb ist leer"
        }
    }
    var emptyDescription: String {
        switch self {
        case .all: "Importierte Dokumente erscheinen hier."
        case .open: "Neu importierte Dokumente erscheinen hier."
        case .completed: "Als erledigt behaltene Dokumente erscheinen hier."
        case .trash: "Entfernte Dokumente werden hier 30 Tage lang aufbewahrt."
        }
    }
    var emptyIcon: String {
        switch self {
        case .all, .open: "tray"
        case .completed: "checkmark.circle"
        case .trash: "trash"
        }
    }
}

private struct DocumentRow: View {
    let document: InboxDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(document.title).font(.headline).lineLimit(1)
            HStack {
                if let deletedAt = document.deletedAt,
                   let deletionDate = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 30, to: deletedAt) {
                    Text("Papierkorb")
                    Text("Löschen am \(deletionDate.formatted(date: .abbreviated, time: .omitted))")
                } else {
                    Text(document.status.title)
                    Text(document.importedAt, style: .date)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct ImportFeedback: Identifiable, Equatable {
    let id = UUID()
    var attachmentCount = 0
    var deadlineCount = 0
    var failedAttachments: [String] = []
    var errorMessage: String?

    init(attachmentCount: Int, deadlineCount: Int, failedAttachments: [String]) {
        self.attachmentCount = attachmentCount
        self.deadlineCount = deadlineCount
        self.failedAttachments = failedAttachments
    }

    init(errorMessage: String) {
        self.errorMessage = errorMessage
    }

    var isError: Bool { errorMessage != nil || !failedAttachments.isEmpty }
    var summary: String {
        if let errorMessage { return "Import fehlgeschlagen · \(errorMessage)" }
        var parts = ["Importiert"]
        if attachmentCount > 0 {
            parts.append("\(attachmentCount) \(attachmentCount == 1 ? "Anhang" : "Anhänge")")
        }
        parts.append("\(deadlineCount) \(deadlineCount == 1 ? "Frist" : "Fristen") erkannt")
        if !failedAttachments.isEmpty {
            parts.append("Nicht verarbeitet: \(failedAttachments.joined(separator: "; "))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ImportFeedbackBanner: View {
    let feedback: ImportFeedback

    var body: some View {
        Label(feedback.summary, systemImage: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(feedback.isError ? Color.orange : Color.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8, y: 3)
            .frame(maxWidth: 760)
    }
}
