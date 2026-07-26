import SwiftData
import SwiftUI

@main
struct BeforeOopsApp: App {
    @StateObject private var appLock = AppLockController()

    var body: some Scene {
        WindowGroup {
            CloudModelContainerRoot()
                .environmentObject(appLock)
        }
    }
}

private struct CloudModelContainerRoot: View {
    private enum LoadingState {
        case loading
        case loaded(ModelContainer)
        case failed(String)
    }

    @State private var loadingState = LoadingState.loading

    var body: some View {
        Group {
            switch loadingState {
            case .loading:
                ProgressView("iCloud-Dokumente werden geladen …")
            case .loaded(let modelContainer):
                SecureAppRoot()
                    .modelContainer(modelContainer)
            case .failed(let message):
                ContentUnavailableView {
                    Label("iCloud nicht verfügbar", systemImage: "icloud.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("Erneut versuchen") {
                        loadingState = .loading
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task(id: isLoading) {
            guard isLoading else { return }
            loadModelContainer()
        }
    }

    private var isLoading: Bool {
        if case .loading = loadingState { true } else { false }
    }

    private func loadModelContainer() {
        let schema = Schema([InboxDocument.self])
        do {
            loadingState = .loaded(try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema,
                    cloudKitDatabase: .private("iCloud.de.lutzfrank.posteingang")
                )
            ))
        } catch {
            loadingState = .failed(
                "BeforeOops konnte die iCloud-Datenbank nicht öffnen. Prüfe deine Internetverbindung und die iCloud-Einstellungen und versuche es erneut.\n\n\(error.localizedDescription)"
            )
        }
    }
}
