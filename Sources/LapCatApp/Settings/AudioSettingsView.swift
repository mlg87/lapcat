import LapCatAudio
import LapCatCore
import SwiftUI

/// Settings → Audio: input device, tap scope, echo cancellation, audio retention.
struct AudioSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("Microphone (“Me”)") {
                Picker("Input device", selection: $settings.audioInputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                    if let uid = settings.audioInputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
                        Text("Unavailable device (\(uid))").tag(Optional(uid))
                    }
                }
                Button("Refresh devices", action: reloadDevices)
                Toggle("Echo cancellation (voice processing)", isOn: $settings.audioVoiceProcessing)
                if !settings.audioVoiceProcessing {
                    Label(
                        "Without echo cancellation, remote voices played on your speakers leak into your microphone "
                            + "and show up as your own lines. Use headphones for the cleanest “Me” transcript.",
                        systemImage: "headphones"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Meeting audio (“Them”)") {
                Picker("Capture", selection: $settings.audioTapScope) {
                    Text("Meeting app only").tag("app")
                    Text("All system audio except LapCat").tag("system")
                }
            }
            Section {
                Picker("Keep recordings", selection: $settings.audioRetention) {
                    ForEach(AudioRetention.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("Applies to future meetings. “Never” deletes audio once the final transcript is done.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadDevices)
    }

    private func reloadDevices() {
        devices = AudioDevices.inputDevices()
    }
}

extension AudioRetention {
    var label: String {
        switch self {
        case .never: "Never"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .forever: "Forever"
        }
    }
}
