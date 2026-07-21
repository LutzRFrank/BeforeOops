import SwiftData
import SwiftUI

@main
struct BeforeOopsApp: App {
    @StateObject private var appLock = AppLockController()
    private let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([InboxDocument.self])
        do {
            sharedModelContainer = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema,
                    cloudKitDatabase: .private("iCloud.de.lutzfrank.posteingang")
                )
            )
        } catch {
            // Keep the app usable locally if iCloud is temporarily unavailable.
            sharedModelContainer = try! ModelContainer(for: schema)
        }
    }

    var body: some Scene {
        WindowGroup {
            SecureAppRoot()
                .environmentObject(appLock)
        }
        .modelContainer(sharedModelContainer)
    }
}
