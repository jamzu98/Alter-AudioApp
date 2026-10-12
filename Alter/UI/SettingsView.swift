import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in model.launchAtLogin = v }
                Toggle("Leave apps alone that play to another device",
                       isOn: Binding(get: { model.settings.onlyTapDefaultDeviceApps },
                                     set: { v in model.updateSettings { $0.onlyTapDefaultDeviceApps = v } }))
                Text("For example a DAW or music player that sends audio straight to an audio interface.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("GraphicEQ import: \(model.settings.graphicEQBandCount) bands",
                        value: Binding(get: { model.settings.graphicEQBandCount },
                                       set: { v in model.updateSettings { $0.graphicEQBandCount = v } }),
                        in: 4...20)
            }

            Section("Audio Access") {
                HStack {
                    switch model.permission.status {
                    case .authorized: Label("System Audio Recording allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied: Label("System Audio Recording denied", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case .unknown: Label("Alter will ask when it first needs access", systemImage: "questionmark.circle")
                    }
                    Spacer()
                    Button("Open Privacy Settings") { AudioCapturePermission.openSystemSettings() }
                }
                Text("Alter only intercepts an app's audio when it changes something: a volume other than 100%, mute, or effects on the current output. Otherwise the audio goes straight to the device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Excluded Apps") {
                let known = model.settings.knownApps.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
                if known.isEmpty {
                    Text("Apps appear here after they play audio.").foregroundStyle(.secondary)
                }
                ForEach(known, id: \.key) { key, name in
                    Toggle(isOn: Binding(get: { model.settings.excludedApps.contains(key) },
                                         set: { v in model.updateSettings { s in
                                             if v { s.excludedApps.insert(key) } else { s.excludedApps.remove(key) }
                                         } })) {
                        VStack(alignment: .leading) {
                            Text(name)
                            Text(key).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .onAppear {
            NSApp.activate()
            launchAtLogin = model.launchAtLogin
            model.permission.refresh()
        }
    }
}
