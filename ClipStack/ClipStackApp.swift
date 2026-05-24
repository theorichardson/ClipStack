import SwiftData
import SwiftUI

@main
struct ClipStackApp: App {
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([ClipboardEntry.self])
        let configuration = ModelConfiguration(
            "ClipStack",
            schema: schema,
            url: AppStorage.appSupportDirectory.appendingPathComponent("history.store"),
            allowsSave: true
        )

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        AppModelContainer.shared = modelContainer
        HotKeyManager.register()

        let context = modelContainer.mainContext
        ClipboardStore.shared.configure(modelContext: context)
        PasteboardMonitor.shared.onNewEntry = { item in
            ClipboardStore.shared.add(item)
        }
        PasteboardMonitor.shared.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .modelContainer(modelContainer)
        } label: {
            Image(systemName: "doc.on.clipboard.fill")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
