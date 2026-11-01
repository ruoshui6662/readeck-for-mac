import SwiftUI

@main
struct ReadeckMacApp: App {
    @StateObject private var model = AppModel(connectionEvents: ConnectionEvents.live())
    @StateObject private var readerPreferences = ReaderPreferences()

    var body: some Scene {
        WindowGroup(id: "library") {
            Group {
            if model.connected {
                LibraryView(model: model)
                    .frame(minWidth: 880, minHeight: 600)
            } else {
                ConnectionView(model: model)
            }
            }.environmentObject(readerPreferences)
        }
        .commands {
            ArtworkCommands()
            CommandGroup(replacing: .newItem) {
                Button("保存网页") { model.showSaveSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            LibraryCommands(model: model)
        }

        MenuBarExtra("Readeck", systemImage: "bookmark") {
            QuickSaveView(model: model)
                .id(model.client?.storageInstance)
        }
        .menuBarExtraStyle(.window)

        Window("艺术封面来源", id: "artwork-credits") { ArtworkCreditsView() }

        Settings {
            SettingsView(model: model).environmentObject(readerPreferences)
        }
    }
}
