import Foundation

/// Approximates a GraphicEQ curve (frequency/gain points) with a small set of biquads:
/// a low shelf, a high shelf and peaking filters placed greedily on the largest error, then
/// refined jointly with Adam on a log-frequency grid.
enum GraphicEQFitter {
    struct Result {
        var preset: EQPreset
        var rmsError: Double
    }

    static let sampleRate = 48_000.0

    static func fit(points: [(Double, Double)], bandCount: Int = 10, iterations: Int = 400) -> Result {
        let grid = FrequencyGrid.log(count: 160, low: 20, high: 20_000)
        let target = grid.map { interpolate(points, at: $0) }
        // Above ~10 kHz measurements are unreliable; weight that region less.
        let weights = grid.map { $0 > 10_000 ? 0.4 : ($0 < 30 ? 0.6 : 1.0) }
        let ctx = Context(grid: grid, target: target, weights: weights)

        let n = max(2, min(20, bandCount))
        var bands: [Param] = []
        var offset = weightedMean(target, weights)

        // Shelves first, like AutoEQ does.
        let lowMean = zip(grid, target).filter { $0.0 < 80 }.map(\.1)
        let highMean = zip(grid, target).filter { $0.0 > 12_000 }.map(\.1)
        bands.append(Param(type: .lowShelf, logF: log10(105), gain: (lowMean.average ?? offset) - offset, logQ: log10(0.7)))
        bands.append(Param(type: .highShelf, logF: log10(10_000), gain: (highMean.average ?? offset) - offset, logQ: log10(0.7)))

        // Greedy peaking placement.
        while bands.count < n {
            offset = ctx.bestOffset(bands)
            let model = ctx.model(bands, offset: offset)
            var worst = 0, worstErr = 0.0
            for i in grid.indices where grid[i] >= 25 && grid[i] <= 16_000 {
                let e = (target[i] - model[i]) * weights[i]
                if abs(e) > abs(worstErr) { worst = i; worstErr = e }
            }
            let residual = target[worst] - model[worst]
            // Estimate width from where the residual falls to half.
            var lo = worst, hi = worst
            while lo > 0, abs(target[lo] - model[lo]) > abs(residual) / 2 { lo -= 1 }
            while hi < grid.count - 1, abs(target[hi] - model[hi]) > abs(residual) / 2 { hi += 1 }
            let width = max(grid[hi] - grid[lo], grid[worst] * 0.1)
            let q = min(6, max(0.5, grid[worst] / width))
            bands.append(Param(type: .peaking, logF: log10(grid[worst]), gain: residual, logQ: log10(q)))
            bands = optimize(bands, ctx: ctx, iterations: iterations / 4)
        }
        bands = optimize(bands, ctx: ctx, iterations: iterations)
        offset = ctx.bestOffset(bands)

        let model = ctx.model(bands, offset: offset)
        var sq = 0.0, wsum = 0.0
        for i in grid.indices { sq += weights[i] * pow(model[i] - target[i], 2); wsum += weights[i] }
        let rms = sqrt(sq / wsum)

        let eqBands = bands
            .map { EQBand(type: $0.type, frequency: ($0.frequency * 10).rounded() / 10, gainDB: ($0.gain * 10).rounded() / 10, q: ($0.q * 100).rounded() / 100) }
            .sorted { ($0.type == .peaking ? 1 : 0, $0.frequency) < ($1.type == .peaking ? 1 : 0, $1.frequency) }
        let preset = EQPreset(name: "Fitted", kind: .correction, source: .imported,
                              preampDB: (offset * 10).rounded() / 10, bands: eqBands)
        return Result(preset: preset, rmsError: rms)
    }

    // MARK: - Internals

    struct Param {
        var type: FilterType
        var logF: Double
        var gain: Double
        var logQ: Double

        var frequency: Double { pow(10, logF) }
        var q: Double { pow(10, logQ) }

        subscript(i: Int) -> Double {
            get { i == 0 ? logF : (i == 1 ? gain / 10 : logQ) }
            set {
                switch i {
                case 0: logF = newValue
                case 1: gain = newValue * 10
                default: logQ = newValue
                }
            }
        }

        mutating func clamp() {
            logF = min(log10(19_000), max(log10(20), logF))
            gain = min(20, max(-20, gain))
            switch type {
            case .lowShelf, .highShelf: logQ = min(log10(1.5), max(log10(0.4), logQ))
            default: logQ = min(log10(8), max(log10(0.18), logQ))
            }
        }
    }

    final class Context {
        let grid: [Double]
        let target: [Double]
        let weights: [Double]
        let cos1: [Double], sin1: [Double], cos2: [Double], sin2: [Double]

        init(grid: [Double], target: [Double], weights: [Double]) {
            self.grid = grid; self.target = target; self.weights = weights
            let w = grid.map { 2 * Double.pi * $0 / GraphicEQFitter.sampleRate }
            cos1 = w.map(cos); sin1 = w.map(sin); cos2 = w.map { cos(2 * $0) }; sin2 = w.map { sin(2 * $0) }
        }

        func response(_ p: Param) -> [Double] {
            let c = BiquadCoefficients.design(p.type, frequency: p.frequency, gainDB: p.gain, q: p.q, sampleRate: GraphicEQFitter.sampleRate)
            var out = [Double](repeating: 0, count: grid.count)
            for i in grid.indices {
                let nr = c.b0 + c.b1 * cos1[i] + c.b2 * cos2[i], ni = -(c.b1 * sin1[i] + c.b2 * sin2[i])
                let dr = 1 + c.a1 * cos1[i] + c.a2 * cos2[i], di = -(c.a1 * sin1[i] + c.a2 * sin2[i])
                out[i] = 10 * log10(max(nr * nr + ni * ni, 1e-30) / max(dr * dr + di * di, 1e-30))
            }
            return out
        }

        func model(_ bands: [Param], offset: Double) -> [Double] {
            var sum = [Double](repeating: offset, count: grid.count)
            for b in bands {
                let r = response(b)
                for i in sum.indices { sum[i] += r[i] }
            }
            return sum
        }

        func bestOffset(_ bands: [Param]) -> Double {
            let m = model(bands, offset: 0)
            return weightedMean(zip(target, m).map { $0 - $1 }, weights)
        }

        func loss(_ sum: [Double]) -> Double {
            var l = 0.0
            for i in grid.indices { l += weights[i] * pow(sum[i] - target[i], 2) }
            return l / Double(grid.count)
        }
    }

    static func optimize(_ start: [Param], ctx: Context, iterations: Int) -> [Param] {
        var bands = start
        let count = bands.count * 3
        var m = [Double](repeating: 0, count: count), v = [Double](repeating: 0, count: count)
        let lr = 0.01, beta1 = 0.9, beta2 = 0.999, eps = 1e-8, h = 1e-4
        var responses = bands.map(ctx.response)

        for t in 1...max(1, iterations) {
            let offset = ctx.bestOffset(bands)
            var base = [Double](repeating: offset, count: ctx.grid.count)
            for r in responses { for i in base.indices { base[i] += r[i] } }
            let l0 = ctx.loss(base)

            var grad = [Double](repeating: 0, count: count)
            for b in bands.indices {
                for k in 0..<3 {
                    var p = bands[b]
                    p[k] += h
                    let r = ctx.response(p)
                    var trial = base
                    for i in trial.indices { trial[i] += r[i] - responses[b][i] }
                    grad[b * 3 + k] = (ctx.loss(trial) - l0) / h
                }
            }
            for j in 0..<count {
                m[j] = beta1 * m[j] + (1 - beta1) * grad[j]
                v[j] = beta2 * v[j] + (1 - beta2) * grad[j] * grad[j]
                let mh = m[j] / (1 - pow(beta1, Double(t))), vh = v[j] / (1 - pow(beta2, Double(t)))
                bands[j / 3][j % 3] -= lr * mh / (sqrt(vh) + eps)
            }
            for b in bands.indices {
                bands[b].clamp()
                responses[b] = ctx.response(bands[b])
            }
        }
        return bands
    }

    static func interpolate(_ points: [(Double, Double)], at f: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if f <= first.0 { return first.1 }
        if f >= last.0 { return last.1 }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].0 <= f { lo = mid } else { hi = mid }
        }
        let (f0, g0) = points[lo], (f1, g1) = points[hi]
        let t = (log10(f) - log10(f0)) / (log10(f1) - log10(f0))
        return g0 + (g1 - g0) * t
    }

    static func weightedMean(_ values: [Double], _ weights: [Double]) -> Double {
        var s = 0.0, w = 0.0
        for (x, wt) in zip(values, weights) { s += x * wt; w += wt }
        return w > 0 ? s / w : 0
    }
}

private extension Array where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}
