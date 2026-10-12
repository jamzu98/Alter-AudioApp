import Foundation
import Synchronization

/// bs2b-style crossfeed coefficients (Boris Mikhaylov's algorithm, reimplemented).
struct CrossfeedCoefficients {
    var a0Lo: Double = 0, b1Lo: Double = 0
    var a0Hi: Double = 1, a1Hi: Double = 0, b1Hi: Double = 0
    var gain: Double = 1

    init() {}

    init(cutoff: Double, feedDB: Double, sampleRate: Double) {
        let level = max(1, min(15, feedDB))
        let gbLo = level * -5 / 6 - 3
        let gbHi = level / 6 - 3
        let gLo = pow(10, gbLo / 20)
        let gHi = 1 - pow(10, gbHi / 20)
        let fcHi = cutoff * pow(2, (gbLo - 20 * log10(gHi)) / 12)

        var x = exp(-2 * Double.pi * cutoff / sampleRate)
        b1Lo = x
        a0Lo = gLo * (1 - x)

        x = exp(-2 * Double.pi * fcHi / sampleRate)
        b1Hi = x
        a0Hi = 1 - gHi * (1 - x)
        a1Hi = -x

        gain = 1 / (1 - gHi + gLo)
    }
}

/// Immutable, fully computed parameters for one effect chain. Created on the main thread and
/// read on the audio thread. Never mutated after init.
final class ChainState {
    static let maxSections = 64

    let sampleRate: Double
    /// When false only per-app volume and software device volume are applied.
    let enabled: Bool
    let preGain: Float
    let sectionCount: Int
    let sections: UnsafeMutablePointer<BiquadCoefficients>
    let crossfeedEnabled: Bool
    let crossfeed: CrossfeedCoefficients
    let gainL: Float
    let gainR: Float
    let softwareGain: Float
    let limiterEnabled: Bool
    let ceiling: Float
    let releaseCoeff: Float
    let lookahead: Int

    init(sampleRate: Double,
         enabled: Bool,
         preGainDB: Double = 0,
         sections: [BiquadCoefficients] = [],
         crossfeed: CrossfeedCoefficients? = nil,
         balance: Double = 0,
         trimDB: Double = 0,
         softwareGain: Float = 1,
         limiter: LimiterSettings? = nil) {
        self.sampleRate = sampleRate
        self.enabled = enabled
        self.preGain = Float(pow(10, preGainDB / 20))
        let list = Array(sections.prefix(Self.maxSections))
        self.sectionCount = list.count
        self.sections = .allocate(capacity: max(1, list.count))
        for (i, c) in list.enumerated() { self.sections[i] = c }
        self.crossfeedEnabled = crossfeed != nil
        self.crossfeed = crossfeed ?? CrossfeedCoefficients()
        let trim = Float(pow(10, trimDB / 20))
        let b = Float(max(-1, min(1, balance)))
        self.gainL = trim * min(1, 1 - b)
        self.gainR = trim * min(1, 1 + b)
        self.softwareGain = softwareGain
        self.limiterEnabled = limiter?.enabled ?? false
        self.ceiling = Float(pow(10, (limiter?.ceilingDB ?? 0) / 20))
        let releaseSamples = max(1, (limiter?.releaseMS ?? 80) / 1000 * sampleRate)
        self.releaseCoeff = Float(exp(-1 / releaseSamples))
        self.lookahead = min(StreamProcessor.maxLookahead - 1, max(1, Int(0.0015 * sampleRate)))
    }

    deinit { sections.deallocate() }

    static func passthrough(sampleRate: Double = 48_000) -> ChainState {
        ChainState(sampleRate: sampleRate, enabled: false)
    }
}

/// Publishes ChainStates to audio threads without locks. Old states are kept alive for a while
/// after being replaced so a render callback that is still using one never sees it freed.
final class ChainHandle: @unchecked Sendable {
    private let pointer = Atomic<UnsafeMutableRawPointer?>(nil)
    private var retired: [(Unmanaged<ChainState>, Date)] = []
    private let lock = NSLock()

    init(_ initial: ChainState) {
        pointer.store(Unmanaged.passRetained(initial).toOpaque(), ordering: .releasing)
    }

    deinit {
        if let p = pointer.load(ordering: .acquiring) {
            Unmanaged<ChainState>.fromOpaque(p).release()
        }
        retired.forEach { $0.0.release() }
    }

    /// Audio thread: the current state (unretained, valid for the duration of a render call).
    @inline(__always)
    func current() -> ChainState {
        Unmanaged<ChainState>.fromOpaque(pointer.load(ordering: .acquiring)!).takeUnretainedValue()
    }

    /// Main thread: replaces the state.
    func publish(_ state: ChainState) {
        let new = Unmanaged.passRetained(state).toOpaque()
        let old = pointer.exchange(new, ordering: .acquiringAndReleasing)
        lock.lock()
        let now = Date()
        if let old { retired.append((Unmanaged<ChainState>.fromOpaque(old), now)) }
        let (expired, keep) = retired.reduce(into: ([Unmanaged<ChainState>](), [(Unmanaged<ChainState>, Date)]())) { acc, item in
            if now.timeIntervalSince(item.1) > 2 { acc.0.append(item.0) } else { acc.1.append(item) }
        }
        retired = keep
        lock.unlock()
        expired.forEach { $0.release() }
        if !keep.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.collect() }
        }
    }

    private func collect() {
        lock.lock()
        let now = Date()
        let expired = retired.filter { now.timeIntervalSince($0.1) > 2 }.map(\.0)
        retired.removeAll { now.timeIntervalSince($0.1) > 2 }
        lock.unlock()
        expired.forEach { $0.release() }
    }
}
