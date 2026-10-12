import SwiftUI

/// Table of a preset's bands plus its preamp.
struct BandEditor: View {
    @Binding var preset: EQPreset
    @Binding var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Preset preamp")
                NumberField(value: $preset.preampDB, format: "%.1f", unit: "dB", range: -30...30, step: 0.5)
                    .frame(width: 110)
                Text("Used when automatic headroom is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var band = EQBand(type: .peaking, frequency: suggestedFrequency, gainDB: 0, q: 1.0)
                    band.id = UUID()
                    preset.bands.append(band)
                    selection = band.id
                } label: { Label("Add Band", systemImage: "plus") }
                .disabled(preset.bands.count >= 30)
                Button {
                    for i in preset.bands.indices where preset.bands[i].type.hasGain { preset.bands[i].gainDB = 0 }
                    preset.preampDB = 0
                } label: { Label("Flatten", systemImage: "arrow.counterclockwise") }
                .help("Set every gain to 0 dB")
            }
            .controlSize(.small)

            HStack(spacing: 8) {
                Text("#").frame(width: 18)
                Text("On").frame(width: 22)
                Text("Type").frame(width: 104, alignment: .leading)
                Text("Frequency").frame(width: 104, alignment: .leading)
                Text("Gain").frame(width: 96, alignment: .leading)
                Text("Q").frame(width: 84, alignment: .leading)
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if preset.bands.isEmpty {
                Text("No bands. Add one, or drag handles on the graph after adding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }

            ForEach($preset.bands) { $band in
                let index = preset.bands.firstIndex { $0.id == band.id } ?? 0
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 18)
                    Toggle("", isOn: $band.enabled).labelsHidden().toggleStyle(.checkbox).frame(width: 22)
                    Picker("", selection: $band.type) {
                        ForEach(FilterType.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 104)
                    NumberField(value: $band.frequency, format: band.frequency >= 1000 ? "%.0f" : "%.1f", unit: "Hz", range: 10...22_000, step: 1, logarithmic: true)
                        .frame(width: 104)
                    NumberField(value: $band.gainDB, format: "%+.1f", unit: "dB", range: -30...30, step: 0.5)
                        .frame(width: 96)
                        .disabled(!band.type.hasGain)
                    NumberField(value: $band.q, format: "%.2f", unit: "", range: 0.05...20, step: 0.05)
                        .frame(width: 84)
                    Spacer()
                    Button {
                        preset.bands.removeAll { $0.id == band.id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove band")
                }
                .controlSize(.small)
                .padding(.vertical, 1)
                .padding(.horizontal, 4)
                .background(selection == band.id ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture { selection = band.id }
            }
        }
    }

    private var suggestedFrequency: Double {
        let used = Set(preset.bands.map { Int($0.frequency) })
        return [1000.0, 2000, 500, 4000, 250, 8000, 125, 63].first { !used.contains(Int($0)) } ?? 1000
    }
}

/// A compact numeric text field with a stepper.
struct NumberField: View {
    @Binding var value: Double
    var format: String
    var unit: String
    var range: ClosedRange<Double>
    var step: Double
    var logarithmic = false

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            if !unit.isEmpty {
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            Stepper("", onIncrement: { bump(1) }, onDecrement: { bump(-1) })
                .labelsHidden()
        }
        .onAppear { text = String(format: format, value) }
        .onChange(of: value) { _, v in if !focused { text = String(format: format, v) } }
    }

    private func bump(_ direction: Double) {
        // Logarithmic fields move by a semitone; linear ones snap to the step.
        let next = logarithmic ? value * pow(2, direction / 12) : ((value + direction * step) / step).rounded() * step
        value = clamp(next)
        text = String(format: format, value)
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-+".contains($0) }
        var parsed = Double(cleaned)
        if parsed != nil, unit == "Hz", text.lowercased().contains("k") { parsed! *= 1000 }
        if let parsed { value = clamp(parsed) }
        text = String(format: format, value)
    }

    private func clamp(_ v: Double) -> Double { min(range.upperBound, max(range.lowerBound, v)) }
}
