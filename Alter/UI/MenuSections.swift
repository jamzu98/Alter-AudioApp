import SwiftUI

// MARK: - Device effects

struct DeviceEffectsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let device = model.currentDevice {
            let profile = model.profile(for: device.uid)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle("Effects · \(device.name)")
                    Spacer()
                    Toggle("", isOn: Binding(get: { profile.enabled }, set: { v in model.updateProfile(device.uid) { $0.enabled = v } }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }

                PresetPickerRow(title: "Correction", systemImage: "headphones",
                                kind: .correction,
                                selection: profile.correctionPresetID,
                                enabled: profile.correctionEnabled,
                                setSelection: { id in model.updateProfile(device.uid) { $0.correctionPresetID = id } },
                                setEnabled: { v in model.updateProfile(device.uid) { $0.correctionEnabled = v } })
                PresetPickerRow(title: "Custom EQ", systemImage: "slider.horizontal.3",
                                kind: .custom,
                                selection: profile.customEQPresetID,
                                enabled: profile.customEQEnabled,
                                setSelection: { id in model.updateProfile(device.uid) { $0.customEQPresetID = id } },
                                setEnabled: { v in model.updateProfile(device.uid) { $0.customEQEnabled = v } })

                EQCurveView(curves: EQCurves.forProfile(profile, model: model, sampleRate: model.devices.sampleRate), compact: true)
                    .frame(height: 64)
                    .opacity(profile.enabled && !model.settings.globalBypass ? 1 : 0.35)
            }
            .disabled(model.settings.globalBypass)
        } else {
            Text("No output device").foregroundStyle(.secondary)
        }
    }
}

struct PresetPickerRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let systemImage: String
    let kind: EQPreset.Kind
    let selection: UUID?
    let enabled: Bool
    let setSelection: (UUID?) -> Void
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { enabled }, set: setEnabled))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: systemImage).frame(width: 16).foregroundStyle(.secondary)
            Text(title).frame(width: 72, alignment: .leading)
            Picker("", selection: Binding(get: { selection }, set: setSelection)) {
                Text("None").tag(UUID?.none)
                let list = model.presets(of: kind)
                if !list.isEmpty { Divider() }
                ForEach(list) { p in
                    Text(p.name).tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

// MARK: - Apps

struct AppsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let apps = model.visibleApps
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Apps")
            if apps.isEmpty {
                Text("No apps are using audio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(apps) { app in AppVolumeRow(app: app) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: apps.count <= 6)
            }
        }
    }
}

struct AppVolumeRow: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp

    var body: some View {
        let volume = model.volume(for: app.id)
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .opacity(app.isPlaying ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(app.isPlaying ? .primary : .secondary)
                HStack(spacing: 6) {
                    Slider(value: Binding(get: { Double(volume.volume) },
                                          set: { model.setVolume(AppVolume(volume: Float($0), muted: volume.muted), for: app.id) }),
                           in: 0...1)
                        .controlSize(.mini)
                    Text("\(Int((volume.volume * 100).rounded()))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
                LevelMeter(key: app.id)
                    .frame(height: 2)
                    .opacity(model.engine.activeKeys.contains(app.id) ? 1 : 0)
            }

            Button {
                model.setVolume(AppVolume(volume: volume.volume, muted: !volume.muted), for: app.id)
            } label: {
                Image(systemName: volume.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(volume.muted ? Color.red : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(volume.muted ? "Unmute" : "Mute")
        }
    }
}

struct LevelMeter: View {
    @Environment(AppModel.self) private var model
    let key: String

    var body: some View {
        // Reading the level here (not in the row) keeps redraws limited to this view.
        let level = model.meters.level(key)
        GeometryReader { geo in
            let db = 20 * log10(max(Double(level), 1e-5))
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(db > -1 ? Color.orange : Color.green.opacity(0.8))
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}
