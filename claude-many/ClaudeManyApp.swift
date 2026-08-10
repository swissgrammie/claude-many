import SwiftUI

@main
struct ClaudeManyApp: App {
    @State private var manager = ProfileManager()

    var body: some Scene {
        WindowGroup("Claude Many") {
            ContentView(manager: manager)
                .onAppear { manager.load() }
        }
        .defaultSize(width: 680, height: 500)

        Settings {
            SettingsView(manager: manager)
        }
    }
}
