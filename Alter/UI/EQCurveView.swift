import SwiftUI

struct EQCurves {
    enum Role { case total, correction, custom, extra }

    struct Curve {
        var role: Role
        var sections: [BiquadCoefficients]
    }

    var curves: [Curve] = []
    var sampleRate: Double = 48_000

    var allSections: [BiquadCoefficients] { curves.flatMap(\.sections) }

    @MainActor
    static func forProfile(_ profile: DeviceProfile, model: AppModel, sampleRate: Double) -> EQCurves {
        var result = EQCurves(sampleRate: sampleRate)
        let correction = profile.correctionEnabled ? model.preset(profile.correctionPresetID) : nil
        let custom = profile.customEQEnabled ? model.preset(profile.customEQPresetID) : nil
        if let correction {
            result.curves.append(.init(role: .correction, sections: correction.activeBands.map { $0.coefficients(sampleRate: sampleRate) }))
        }
        if let custom {
            result.curves.append(.init(role: .custom, sections: custom.activeBands.map { $0.coefficients(sampleRate: sampleRate) }))
        }
        var extraProfile = profile
        extraProfile.correctionEnabled = false
        extraProfile.customEQEnabled = false
        let extra = ChainBuilder.sections(.init(profile: extraProfile, volumeDB: Double(model.devices.volumeDecibels), sampleRate: sampleRate))
        if !extra.isEmpty { result.curves.append(.init(role: .extra, sections: extra)) }
        return result
    }
}

/// Frequency response plot. When `bands` is set, its bands get draggable handles.
struct EQCurveView: View {
    var curves: EQCurves
    var compact = false
    var bands: Binding<[EQBand]>?
    var selection: Binding<UUID?>?

    private static let fLow = 20.0, fHigh = 20_000.0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let range = dbRange
            ZStack {
                Canvas { ctx, size in
                    drawGrid(ctx, size, range)
                    for curve in curves.curves where curves.curves.count > 1 || curve.role == .extra {
                        drawCurve(ctx, size, range, sections: curve.sections, color: color(for: curve.role).opacity(0.55), width: 1)
                    }
                    drawCurve(ctx, size, range, sections: curves.allSections, color: .accentColor, width: compact ? 1.5 : 2.2, fill: true)
                }
                if let bands, !compact {
                    ForEach(bands.wrappedValue.indices, id: \.self) { i in
                        handle(index: i, bands: bands, size: size, range: range)
                    }
                }
            }
        }
        .background(compact ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.6)),
                    in: RoundedRectangle(cornerRadius: compact ? 6 : 10))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10))
    }

    private var dbRange: Double {
        if compact { return 12 }
        let peak = FrequencyGrid.log(count: 96).map { f in
            abs(curves.allSections.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: curves.sampleRate) })
        }.max() ?? 0
        return max(12, (peak / 6).rounded(.up) * 6)
    }

    private func color(for role: EQCurves.Role) -> Color {
        switch role {
        case .total: .accentColor
        case .correction: .teal
        case .custom: .purple
        case .extra: .orange
        }
    }

    // MARK: Mapping

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((log10(f) - log10(Self.fLow)) / (log10(Self.fHigh) - log10(Self.fLow))) * w
    }

    private func f(_ x: CGFloat, _ w: CGFloat) -> Double {
        pow(10, log10(Self.fLow) + Double(x / w) * (log10(Self.fHigh) - log10(Self.fLow)))
    }

    private func y(_ db: Double, _ h: CGFloat, _ range: Double) -> CGFloat {
        h / 2 - CGFloat(db / range) * (h / 2 - 6)
    }

    private func db(_ y: CGFloat, _ h: CGFloat, _ range: Double) -> Double {
        Double((h / 2 - y) / (h / 2 - 6)) * range
    }

    // MARK: Drawing

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize, _ range: Double) {
        let grid = Color.secondary.opacity(compact ? 0.12 : 0.18)
        var path = Path()
        for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
            let px = x(f, size.width)
            path.move(to: CGPoint(x: px, y: 0)); path.addLine(to: CGPoint(x: px, y: size.height))
        }
        let step = range > 12 ? 6.0 : 3.0
        var d = -range
        while d <= range {
            let py = y(d, size.height, range)
            path.move(to: CGPoint(x: 0, y: py)); path.addLine(to: CGPoint(x: size.width, y: py))
            d += step
        }
        ctx.stroke(path, with: .color(grid), lineWidth: 0.5)
        var zero = Path()
        let py = y(0, size.height, range)
        zero.move(to: CGPoint(x: 0, y: py)); zero.addLine(to: CGPoint(x: size.width, y: py))
        ctx.stroke(zero, with: .color(.secondary.opacity(0.4)), lineWidth: 0.8)

        guard !compact else { return }
        for (f, label) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            ctx.draw(Text(label).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: x(f, size.width) + 3, y: size.height - 8), anchor: .leading)
        }
        var labelDB = -range + step
        while labelDB < range {
            ctx.draw(Text(String(format: "%+.0f", labelDB)).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: 4, y: y(labelDB, size.height, range)), anchor: .leading)
            labelDB += step
        }
    }

    private func drawCurve(_ ctx: GraphicsContext, _ size: CGSize, _ range: Double, sections: [BiquadCoefficients],
                           color: Color, width: CGFloat, fill: Bool = false) {
        let points = max(64, Int(size.width / 2))
        var path = Path()
        for i in 0...points {
            let px = size.width * CGFloat(i) / CGFloat(points)
            let freq = f(px, size.width)
            let value = sections.reduce(0) { $0 + $1.magnitudeDB(at: freq, sampleRate: curves.sampleRate) }
            let p = CGPoint(x: px, y: y(max(-range, min(range, value)), size.height, range))
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        if fill {
            var area = path
            let zero = y(0, size.height, range)
            area.addLine(to: CGPoint(x: size.width, y: zero))
            area.addLine(to: CGPoint(x: 0, y: zero))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.12)))
        }
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }

    // MARK: Handles

    @ViewBuilder
    private func handle(index i: Int, bands: Binding<[EQBand]>, size: CGSize, range: Double) -> some View {
        let band = bands.wrappedValue[i]
        let selected = selection?.wrappedValue == band.id
        let gain = band.type.hasGain ? band.gainDB : 0
        Circle()
            .fill(selected ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .overlay(Text("\(i + 1)").font(.system(size: 8, weight: .bold)).foregroundStyle(selected ? .white : .accentColor))
            .frame(width: 16, height: 16)
            .opacity(band.enabled ? 1 : 0.4)
            .position(x: x(band.frequency, size.width), y: y(max(-range, min(range, gain)), size.height, range))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selection?.wrappedValue = band.id
                        guard i < bands.wrappedValue.count else { return }
                        var b = bands.wrappedValue[i]
                        let px = max(0, min(size.width, value.location.x))
                        b.frequency = (f(px, size.width) * 10).rounded() / 10
                        if b.type.hasGain {
                            let g = db(value.location.y, size.height, range)
                            b.gainDB = (max(-range, min(range, g)) * 10).rounded() / 10
                        }
                        bands.wrappedValue[i] = b
                    }
            )
            .help("\(band.type.displayName) \(Int(band.frequency)) Hz \(String(format: "%+.1f", band.gainDB)) dB Q \(String(format: "%.2f", band.q))")
    }
}
