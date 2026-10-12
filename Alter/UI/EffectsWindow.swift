import SwiftUI
import UniformTypeIdentifiers

struct EffectsWindow: View {
    @Environment(AppModel.self) private var model
    @State private var selectedUID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedUID) {
                Section("Output Devices") {
                    ForEach(model.profileDevices, id: \.uid) { item in
                        HStack {
                            Image(systemName: model.devices.outputs.first { $0.uid == item.uid }?.symbolName ?? "hifispeaker")
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                if item.uid == model.currentDevice?.uid {
                                    // Accent text vanishes on the accent selection highlight; the
                                    // hierarchical style adapts to it instead.
                                    Text("Active")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(selectedUID == item.uid ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                                } else if !item.connected {
                                    Text("Not connected").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .help(item.connected ? "Double-click to use as output" : "Not connected")
                        .tag(item.uid)
                    }
                }
            }
            // Double-click (the list's primary action) makes a connected device the system output.
            .contextMenu(forSelectionType: String.self) { uids in
                if let uid = uids.first {
                    if let device = connectedDevice(uid) {
                        Button("Use as Output") { model.devices.setDefaultOutput(device) }
                            .disabled(uid == model.currentDevice?.uid)
                    } else {
                        Button("Forget Device") { model.forgetProfile(uid) }
                    }
                }
            } primaryAction: { uids in
                if let uid = uids.first, let device = connectedDevice(uid) {
                    model.devices.setDefaultOutput(device)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if let uid = selectedUID ?? model.currentDevice?.uid {
                DeviceEffectsEditor(uid: uid)
                    .id(uid)
            } else {
                ContentUnavailableView("No Output Device", systemImage: "hifispeaker")
            }
        }
        .onAppear {
            NSApp.activate()
            if selectedUID == nil { selectedUID = model.currentDevice?.uid }
        }
    }

    private func connectedDevice(_ uid: String) -> OutputDevice? {
        model.devices.outputs.first { $0.uid == uid }
    }
}

struct DeviceEffectsEditor: View {
    @Environment(AppModel.self) private var model
    let uid: String

    @State private var editing: EQPreset.Kind = .correction
    @State private var selectedBand: UUID?
    @State private var importKind: EQPreset.Kind?
    @State private var showAutoEQ = false
    @State private var renameTarget: EQPreset?
    @State private var renameText = ""
    @State private var importError: String?
    @State private var importing = false

    private var profile: DeviceProfile { model.profile(for: uid) }

    private func update(_ change: (inout DeviceProfile) -> Void) { model.updateProfile(uid, change) }

    private func binding<T>(_ keyPath: WritableKeyPath<DeviceProfile, T>) -> Binding<T> {
        Binding(get: { profile[keyPath: keyPath] }, set: { v in update { $0[keyPath: keyPath] = v } })
    }

    private var sampleRate: Double { uid == model.currentDevice?.uid ? model.devices.sampleRate : 48_000 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                graph
                presetSlots
                if let preset = editedPreset {
                    GroupBox {
                        BandEditor(preset: presetBinding(preset), selection: $selectedBand)
                            .padding(6)
                    } label: {
                        Text("Bands · \(preset.name)").font(.headline)
                    }
                }
                effectsGrid
            }
            .padding(20)
            .disabled(importing)
        }
        .navigationTitle(profile.deviceName.isEmpty ? "Effects" : profile.deviceName)
        .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                      allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "txt") ?? .plainText],
                      allowsMultipleSelection: true) { result in
            let kind = importKind ?? .correction
            if case let .success(urls) = result { importFiles(urls, kind: kind) }
        }
        .sheet(isPresented: $showAutoEQ) {
            AutoEQSearchView { preset in
                let added = model.addPreset(preset)
                update { $0.correctionPresetID = added.id; $0.correctionEnabled = true }
                editing = .correction
            }
            .environment(model)
        }
        .alert("Rename Preset", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if var p = renameTarget, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    p.name = renameText
                    model.updatePreset(p)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Import Failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .overlay {
            if importing { ProgressView("Fitting GraphicEQ…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
        }
    }

    // MARK: Header & graph

    private var header: some View {
        HStack {
            Text(profile.deviceName).font(.title2.weight(.semibold))
            Spacer()
            sampleRatePicker
                .padding(.trailing, 12)
            Toggle("Effects", isOn: binding(\.enabled))
                .toggleStyle(.switch)
        }
    }

    private var connectedDevice: OutputDevice? { model.devices.outputs.first { $0.uid == uid } }

    /// Shows the device's current sample rate. Picking one saves it for this device, and it is
    /// re-applied whenever the device connects or becomes the output.
    @ViewBuilder
    private var sampleRatePicker: some View {
        let device = connectedDevice
        // Live rate while connected; the saved one otherwise.
        if let shown = model.devices.currentRates[uid] ?? profile.sampleRate {
            let rates = Array(Set((device?.sampleRates ?? []) + [shown])).sorted()
            Picker("Sample Rate", selection: Binding(get: { shown }, set: { model.setSampleRate($0, for: uid) })) {
                ForEach(rates, id: \.self) { Text(SampleRateFormat.label($0)).tag($0) }
            }
            .fixedSize()
            .disabled(device == nil || device?.canSetSampleRate == false || rates.count < 2)
        }
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Edit", selection: $editing) {
                    Text("Correction").tag(EQPreset.Kind.correction)
                    Text("Custom EQ").tag(EQPreset.Kind.custom)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Spacer()
                legend
            }
            EQCurveView(curves: EQCurves.forProfile(profile, model: model, sampleRate: sampleRate),
                        bands: editedPreset.map { p in presetBinding(p).bands },
                        selection: $selectedBand)
                .frame(height: 260)
            Text(preampSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(profile.enabled ? 1 : 0.5)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem("Total", .accentColor)
            legendItem("Correction", .teal)
            legendItem("Custom", .purple)
            legendItem("Tone/Loudness", .orange)
        }
        .font(.caption)
    }

    private func legendItem(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).foregroundStyle(.secondary)
        }
    }

    private var preampSummary: String {
        let inputs = ChainBuilder.Inputs(profile: profile,
                                         correction: model.preset(profile.correctionPresetID),
                                         custom: model.preset(profile.customEQPresetID),
                                         volumeDB: Double(model.devices.volumeDecibels),
                                         sampleRate: sampleRate)
        let sections = ChainBuilder.sections(inputs)
        let pre = ChainBuilder.preampDB(inputs, sections: sections)
        let boost = ChainBuilder.maxBoostDB(sections, sampleRate: sampleRate)
        // Round first so tiny negatives don't print as "-0.0".
        func f(_ v: Double) -> String { String(format: "%+.1f", (v * 10).rounded() / 10 + 0) }
        return "Max boost \(f(boost)) dB · effective preamp \(f(pre)) dB · gain trim \(f(profile.gainTrimDB)) dB"
    }

    // MARK: Presets

    private var editedPreset: EQPreset? {
        model.preset(editing == .correction ? profile.correctionPresetID : profile.customEQPresetID)
    }

    private func presetBinding(_ preset: EQPreset) -> Binding<EQPreset> {
        Binding(get: { model.preset(preset.id) ?? preset }, set: { model.updatePreset($0) })
    }

    private var presetSlots: some View {
        HStack(alignment: .top, spacing: 14) {
            presetSlot(.correction, title: "Headphone / Speaker Correction",
                       selection: binding(\.correctionPresetID), enabled: binding(\.correctionEnabled))
            presetSlot(.custom, title: "Custom EQ",
                       selection: binding(\.customEQPresetID), enabled: binding(\.customEQEnabled))
        }
    }

    private func presetSlot(_ kind: EQPreset.Kind, title: String,
                            selection: Binding<UUID?>, enabled: Binding<Bool>) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("", isOn: enabled).labelsHidden()
                    Picker("", selection: selection) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.presets(of: kind)) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .onChange(of: selection.wrappedValue) { _, _ in editing = kind }
                }
                if let preset = model.preset(selection.wrappedValue), !preset.notes.isEmpty {
                    Text(preset.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    if kind == .correction {
                        Button { showAutoEQ = true } label: { Label("AutoEQ…", systemImage: "magnifyingglass") }
                    }
                    Button { importKind = kind } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                    Menu {
                        Button("New Flat Preset") { create(kind, from: .flat(name: "New Preset", kind: kind), selection: selection) }
                        Button("New 10-Band Preset") {
                            var p = EQPreset.tenBand(name: "New 10-Band")
                            p.kind = kind
                            create(kind, from: p, selection: selection)
                        }
                        Button("Paste from Clipboard") { pasteImport(kind) }
                        if let preset = model.preset(selection.wrappedValue) {
                            Divider()
                            Button("Duplicate") {
                                var copy = preset
                                copy.id = UUID(); copy.name += " Copy"; copy.source = .user; copy.created = Date()
                                create(kind, from: copy, selection: selection)
                            }
                            Button("Rename…") { renameText = preset.name; renameTarget = preset }
                            Button("Move to \(kind == .correction ? "Custom EQ" : "Correction")") {
                                var moved = preset
                                moved.kind = kind == .correction ? .custom : .correction
                                model.updatePreset(moved)
                                selection.wrappedValue = nil
                            }
                            Button("Export…") { export(preset) }
                            Button("Copy as Text") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(PresetExporter.parametricText(preset), forType: .string)
                            }
                            Divider()
                            Button("Delete", role: .destructive) { model.deletePreset(preset.id) }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .fixedSize()
                }
                .controlSize(.small)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.headline)
        }
    }

    private func create(_ kind: EQPreset.Kind, from preset: EQPreset, selection: Binding<UUID?>) {
        let added = model.addPreset(preset)
        selection.wrappedValue = added.id
        editing = kind
    }

    private func importFiles(_ urls: [URL], kind: EQPreset.Kind) {
        let bands = model.settings.graphicEQBandCount
        importing = true
        Task.detached {
            var imported: [EQPreset] = []
            var failures: [String] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    var preset = try PresetParser.parse(text, name: Self.presetName(from: url), bandCount: bands)
                    preset.kind = kind
                    imported.append(preset)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            let done = imported, failed = failures
            await MainActor.run {
                importing = false
                var last: EQPreset?
                for p in done { last = model.addPreset(p) }
                if let last {
                    assign(last.id, to: kind)
                    editing = kind
                }
                if !failed.isEmpty { importError = failed.joined(separator: "\n") }
            }
        }
    }

    private func assign(_ id: UUID, to kind: EQPreset.Kind) {
        update { p in
            if kind == .correction { p.correctionPresetID = id; p.correctionEnabled = true } else { p.customEQPresetID = id; p.customEQEnabled = true }
        }
    }

    private func pasteImport(_ kind: EQPreset.Kind) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            importError = "The clipboard contains no text."
            return
        }
        do {
            var preset = try PresetParser.parse(text, name: "Pasted Preset", bandCount: model.settings.graphicEQBandCount)
            preset.kind = kind
            let added = model.addPreset(preset)
            assign(added.id, to: kind)
            editing = kind
        } catch {
            importError = error.localizedDescription
        }
    }

    static func frequencyLabel(_ f: Double) -> String {
        f >= 1000 ? "\(Int(f / 1000)) kHz" : "\(Int(f)) Hz"
    }

    nonisolated static func presetName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for suffix in [" ParametricEQ", " GraphicEQ", " FixedBandEQ"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    private func export(_ preset: EQPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(preset.name) ParametricEQ.txt"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PresetExporter.parametricText(preset).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            importError = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Effects

    private var effectsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)],
                  alignment: .leading, spacing: 14) {
            EffectBox(title: "Preamp", systemImage: "dial.low") {
                Toggle("Automatic headroom", isOn: binding(\.autoPreamp))
                    .help("Lowers the level by the largest EQ boost so nothing clips.")
                LabeledSlider(title: profile.autoPreamp ? "Extra offset" : "Preamp", value: binding(\.preampDB), range: -24...12, unit: "dB")
            }
            EffectBox(title: "Gain Trim", systemImage: "speaker.wave.2") {
                Text("Level-match this device against others, after all effects.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledSlider(title: "Gain", value: binding(\.gainTrimDB), range: -24...12, unit: "dB")
            }
            EffectBox(title: "Tone", systemImage: "slider.horizontal.below.rectangle", isOn: binding(\.tone.enabled)) {
                Toggle("Pultec", isOn: binding(\.tone.pultec))
                    .help("Pultec EQP-1A style curves: bass boost adds the low-mid dip above it, treble boost is a broad bell instead of a shelf.")
                LabeledSlider(title: "Bass", value: binding(\.tone.bassDB), range: -12...12, unit: "dB")
                LabeledSlider(title: "Treble", value: binding(\.tone.trebleDB), range: -12...12, unit: "dB")
                if profile.tone.pultec {
                    HStack {
                        Picker("Low", selection: binding(\.tone.pultecLowFrequency)) {
                            ForEach(ToneSettings.pultecLowFrequencies, id: \.self) { Text(Self.frequencyLabel($0)).tag($0) }
                        }
                        Picker("High", selection: binding(\.tone.pultecHighFrequency)) {
                            ForEach(ToneSettings.pultecHighFrequencies, id: \.self) { Text(Self.frequencyLabel($0)).tag($0) }
                        }
                    }
                    .controlSize(.small)
                }
            }
            EffectBox(title: "Loudness", systemImage: "ear", isOn: binding(\.loudness.enabled)) {
                Text("Adds bass and treble as the volume goes down, to make up for how hearing works at low levels.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledSlider(title: "Amount", value: binding(\.loudness.amount), range: 0...1, unit: "%", scale: 100)
                LabeledSlider(title: "Reference", value: binding(\.loudness.referenceDB), range: -30...0, unit: "dB")
            }
            EffectBox(title: "Crossfeed", systemImage: "headphones", isOn: binding(\.crossfeed.enabled)) {
                Picker("Preset", selection: binding(\.crossfeed.preset)) {
                    ForEach(CrossfeedSettings.Preset.allCases) { Text($0.displayName).tag($0) }
                }
                if profile.crossfeed.preset == .custom {
                    LabeledSlider(title: "Cutoff", value: binding(\.crossfeed.cutoff), range: 300...2000, unit: "Hz", decimals: 0)
                    LabeledSlider(title: "Feed", value: binding(\.crossfeed.feedDB), range: 1...15, unit: "dB")
                }
            }
            EffectBox(title: "Balance", systemImage: "arrow.left.and.right") {
                LabeledSlider(title: "L / R", value: binding(\.balance), range: -1...1, unit: "", scale: 100, decimals: 0)
                Button("Center") { update { $0.balance = 0 } }.controlSize(.small)
            }
            EffectBox(title: "Limiter", systemImage: "waveform.badge.minus", isOn: binding(\.limiter.enabled)) {
                LabeledSlider(title: "Ceiling", value: binding(\.limiter.ceilingDB), range: -12...0, unit: "dB")
                LabeledSlider(title: "Release", value: binding(\.limiter.releaseMS), range: 10...500, unit: "ms", decimals: 0)
            }
        }
        .disabled(!profile.enabled)
    }
}

struct EffectBox<Content: View>: View {
    let title: String
    let systemImage: String
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isOn.map { !$0.wrappedValue } ?? false)
                .opacity(isOn.map { $0.wrappedValue ? 1 : 0.5 } ?? 1)
        } label: {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                if let isOn { Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden() }
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    var scale: Double = 1
    var decimals = 1

    var body: some View {
        HStack {
            Text(title).frame(width: 82, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(String(format: "%.\(decimals)f", value * scale) + (unit.isEmpty ? "" : " \(unit)"))
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
        }
        .contextMenu { Button("Reset") { value = min(range.upperBound, max(range.lowerBound, 0)) } }
    }
}
