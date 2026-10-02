import LapCatCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    KeyRecorderView(action: action)
                }
            }
            Section("Permissions") {
                Button("Show permissions checklist…") { appState.showPermissions() }
            }
        }
        .formStyle(.grouped)
    }
}
