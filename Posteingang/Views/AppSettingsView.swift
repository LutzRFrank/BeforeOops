import CloudKit
import SwiftUI

enum ReminderLeadTime: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case oneWeek = 7
    case oneMonth = 30

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .oneDay: "1 Tag vorher"
        case .oneWeek: "1 Woche vorher"
        case .oneMonth: "1 Monat vorher"
        }
    }
}

enum InboxSortOrder: String, CaseIterable, Identifiable {
    case manual
    case newest
    case oldest
    case title

    var id: Self { self }
    var title: String {
        switch self {
        case .manual: "Manuell"
        case .newest: "Neueste zuerst"
        case .oldest: "Älteste zuerst"
        case .title: "Titel A–Z"
        }
    }
}

struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reminderLeadDays") private var reminderLeadDays = ReminderLeadTime.oneWeek.rawValue
    @AppStorage("hideCompletedDocuments") private var hideCompletedDocuments = true
    @AppStorage("inboxSortOrder") private var sortOrder = InboxSortOrder.manual.rawValue
    @State private var cloudStatus = "Wird geprüft …"
    @State private var isShowingOnboarding = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Erinnerungen") {
                    Picker("Standardhinweis", selection: $reminderLeadDays) {
                        ForEach(ReminderLeadTime.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                }

                Section("Posteingang") {
                    Toggle("Erledigte automatisch ausblenden", isOn: $hideCompletedDocuments)
                    Picker("Standardsortierung", selection: $sortOrder) {
                        ForEach(InboxSortOrder.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                }

                Section("iCloud") {
                    LabeledContent("Synchronisierung", value: cloudStatus)
                    Text("BeforeOops synchronisiert Dokumente und Originaldateien automatisch über deinen privaten iCloud-Account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Papierkorb") {
                    Text("Einträge im Papierkorb werden nach 30 Tagen automatisch endgültig gelöscht.")
                        .foregroundStyle(.secondary)
                }

                Section("Datenschutz") {
                    Button("Datenschutz & Einführung anzeigen") {
                        isShowingOnboarding = true
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Einstellungen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task { await updateCloudStatus() }
            .sheet(isPresented: $isShowingOnboarding) {
                OnboardingView()
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func updateCloudStatus() async {
        do {
            switch try await CKContainer(identifier: "iCloud.de.lutzfrank.posteingang").accountStatus() {
            case .available: cloudStatus = "Aktiv"
            case .noAccount: cloudStatus = "Kein Account"
            case .restricted: cloudStatus = "Eingeschränkt"
            case .couldNotDetermine: cloudStatus = "Nicht bestimmbar"
            case .temporarilyUnavailable: cloudStatus = "Vorübergehend nicht verfügbar"
            @unknown default: cloudStatus = "Unbekannt"
            }
        } catch {
            cloudStatus = "Nicht verfügbar"
        }
    }
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Willkommen bei BeforeOops")
                    .font(.largeTitle.bold())
                Text("Dokumente prüfen, Fristen erkennen und nichts Wichtiges übersehen.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 22) {
                onboardingPoint(
                    icon: "brain.head.profile",
                    title: "Analyse erfolgt lokal",
                    text: "Texterkennung und Intelligence-Auswertung laufen auf deinem Gerät."
                )
                onboardingPoint(
                    icon: "doc.badge.checkmark",
                    title: "Originale bleiben unverändert",
                    text: "Dateien in Finder, Mail oder anderen Apps werden von BeforeOops nicht verändert."
                )
                onboardingPoint(
                    icon: "icloud",
                    title: "Dein persönliches iCloud-Konto",
                    text: "Wenn iCloud verfügbar ist, synchronisiert BeforeOops seine Einträge privat zwischen deinen Geräten."
                )
            }
            .frame(maxWidth: 560)
            Spacer()
            Button("Loslegen") {
                hasCompletedOnboarding = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .interactiveDismissDisabled(!hasCompletedOnboarding)
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 620)
        #endif
    }

    private func onboardingPoint(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
