import SwiftUI

@main
struct OppyApp: App {
    @StateObject private var appState = AppStateStore()

    var body: some Scene {
        MenuBarExtra("Oppy", systemImage: appState.menuBarIconName) {
            PopoverView(appState: appState)
                .frame(width: 360)
                .padding(.vertical, 8)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .frame(width: 620, height: 520)
        }
    }
}
