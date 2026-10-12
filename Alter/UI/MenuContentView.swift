import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.permission.status == .denied { permissionBanner }
            OutputSection()
            Divider()
            DeviceEffectsCard()
            Divider()
            AppsSection()
            if let error = model.engine.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(WindowReader { window in model.startMeters(in: window) })
        .onAppear {
            model.permission.refresh()
            model.reconcile()
        }
        .onDisappear { model.stopMeters() }
    }

    private var header: some View {
        HStack {
            Text("Alter").font(.headline)
            Spacer()
            Button {
                model.updateSettings { $0.globalBypass.toggle() }
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(model.settings.globalBypass ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(model.settings.globalBypass ? "Effects bypassed on all devices – click to enable" : "Bypass effects on all devices")

            Menu {
                Button("Effects…") { open(WindowID.effects) }
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Divider()
                Button("Quit Alter") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Audio access is off", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Alter needs System Audio Recording permission to control app volume and apply effects.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Privacy Settings") { AudioCapturePermission.openSystemSettings() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func open(_ id: String) {
        NSApp.activate()
        openWindow(id: id)
    }
}

// MARK: - Output

struct OutputSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Output")
            ForEach(model.devices.outputs) { device in
                let selected = device.uid == model.currentDevice?.uid
                Button {
                    model.devices.setDefaultOutput(device)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: device.symbolName)
                            .frame(width: 20)
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                        Text(device.name)
                            .lineLimit(1)
                        Spacer()
                        if hasEffects(device) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("This device has effects")
                        }
                        if selected {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            MasterVolumeRow()
                .padding(.top, 4)
            SampleRateRow()
        }
    }

    private func hasEffects(_ device: OutputDevice) -> Bool {
        guard let p = model.profiles[device.uid], p.enabled else { return false }
        return p.correctionPresetID != nil || p.customEQPresetID != nil || p.tone.enabled || p.crossfeed.enabled || p.loudness.enabled
    }
}

struct MasterVolumeRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            if let volume = model.devices.hardwareVolume {
                Button {
                    model.devices.setMuted(!model.devices.hardwareMuted)
                } label: {
                    Image(systemName: speakerSymbol(volume: volume, muted: model.devices.hardwareMuted))
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .disabled(!model.devices.supportsHardwareMute)
                Slider(value: Binding(get: { Double(volume) }, set: { model.devices.setVolume(Float($0)) }), in: 0...1)
                    .controlSize(.small)
            } else {
                Image(systemName: speakerSymbol(volume: model.softwareVolume, muted: false))
                    .frame(width: 20)
                    .help("This device has no volume control; Alter adjusts it in software.")
                Slider(value: Binding(get: { Double(model.softwareVolume) }, set: { model.setSoftwareVolume(Float($0)) }), in: 0...1)
                    .controlSize(.small)
            }
        }
    }
}

/// Shows the active output's current sample rate; picking one changes it and saves it for that device.
struct SampleRateRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let device = model.currentDevice, !device.sampleRates.isEmpty {
            let current = model.devices.currentRates[device.uid] ?? model.devices.sampleRate
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text("Sample Rate")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(get: { current }, set: { model.setSampleRate($0, for: device.uid) })) {
                    ForEach(Array(Set(device.sampleRates + [current])).sorted(), id: \.self) { rate in
                        Text(SampleRateFormat.label(rate)).tag(rate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .disabled(!device.canSetSampleRate || device.sampleRates.count < 2)
            }
            .font(.callout)
        }
    }
}

enum SampleRateFormat {
    /// 44100 → "44.1 kHz", 48000 → "48 kHz".
    static func label(_ rate: Double) -> String {
        let k = rate / 1000
        return k.rounded() == k ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }
}

func speakerSymbol(volume: Float, muted: Bool) -> String {
    if muted || volume <= 0.001 { return "speaker.slash.fill" }
    if volume < 0.33 { return "speaker.wave.1.fill" }
    if volume < 0.66 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// Reports the window hosting a SwiftUI view whenever it is attached to one (each time the menu opens).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        let onWindow: (NSWindow?) -> Void
        private var observer: NSObjectProtocol?

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            onWindow(window)
            // The menu window is reused between openings; restart meters each time it shows.
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: window, queue: .main) { [weak self] _ in
                guard let self, let window = self.window, window.occlusionState.contains(.visible) else { return }
                self.onWindow(window)
            }
        }
    }
}
