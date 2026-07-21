import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockController: ObservableObject {
    @Published private(set) var isLocked = true
    @Published private(set) var isAuthenticating = false
    @Published var authenticationError: String?

    func lock() {
        isLocked = true
        authenticationError = nil
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        authenticationError = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        var authorizationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authorizationError) else {
            authenticationError = authorizationError?.localizedDescription
                ?? "Auf diesem Gerät ist keine Authentifizierung eingerichtet."
            return
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Geschützte Dokumente in BeforeOops öffnen"
            )
            if success { isLocked = false }
        } catch {
            authenticationError = error.localizedDescription
        }
    }
}

struct SecureAppRoot: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appLock: AppLockController

    var body: some View {
        ZStack {
            InboxView()

            if appLock.isLocked || scenePhase != .active {
                privacyShield
            }
        }
        .task {
            await authenticateAndReveal()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                if appLock.isLocked {
                    Task { await appLock.unlock() }
                }
            case .inactive:
                break
            case .background:
                appLock.lock()
            @unknown default:
                break
            }
        }
    }

    private func authenticateAndReveal() async {
        await appLock.unlock()
    }

    private var privacyShield: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("BeforeOops geschützt")
                    .font(.title2.bold())
                if appLock.isAuthenticating {
                    ProgressView("Authentifizierung …")
                } else {
                    Button("Entsperren", systemImage: "touchid") {
                        Task { await appLock.unlock() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let message = appLock.authenticationError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
    }
}
