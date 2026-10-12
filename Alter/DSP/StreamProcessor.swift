import Foundation

/// Per-stream DSP state. Owned by one audio thread; all memory is allocated up front.
/// Signal flow: app gain × preamp → EQ sections → crossfeed → balance/trim → limiter → software volume.
final class StreamProcessor {
    static let maxLookahead = 2048

    // Biquad state, transposed direct form II: [section][channel] -> (z1, z2)
    private let z: UnsafeMutablePointer<Double>
    // Crossfeed state
    private var cfLoL = 0.0, cfLoR = 0.0, cfHiL = 0.0, cfHiR = 0.0, cfAsisL = 0.0, cfAsisR = 0.0
    // Limiter
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private var delayPos = 0
    private var envelope: Float = 1
    private var heldGain: Float = 1
    private var holdCounter = 0
    // Smoothed gains
    private var curInGain: Float = 0
    private var curGainL: Float = 1
    private var curGainR: Float = 1
    private var curSoftware: Float = 1
    private var lastState: ChainState?
    private var lastWasEnabled = false
    private var lastLookahead = 0
    private var lastSectionCount = 0

    init() {
        z = .allocate(capacity: ChainState.maxSections * 4)
        z.initialize(repeating: 0, count: ChainState.maxSections * 4)
        delayL = .allocate(capacity: Self.maxLookahead)
        delayR = .allocate(capacity: Self.maxLookahead)
        delayL.initialize(repeating: 0, count: Self.maxLookahead)
        delayR.initialize(repeating: 0, count: Self.maxLookahead)
    }

    deinit {
        z.deallocate(); delayL.deallocate(); delayR.deallocate()
    }

    func reset() {
        z.update(repeating: 0, count: ChainState.maxSections * 4)
        delayL.update(repeating: 0, count: Self.maxLookahead)
        delayR.update(repeating: 0, count: Self.maxLookahead)
        cfLoL = 0; cfLoR = 0; cfHiL = 0; cfHiR = 0; cfAsisL = 0; cfAsisR = 0
        envelope = 1; heldGain = 1; holdCounter = 0; delayPos = 0
    }

    /// Processes `frames` stereo samples in place. `appGain` is the target per-app gain (0 when muted).
    /// Returns the output peak.
    @discardableResult
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                 state: ChainState, appGain: Float) -> Float {
        guard frames > 0 else { return 0 }
        if state !== lastState { stateChanged(to: state) }
        let invN = 1 / Float(frames)

        // 1. Input gain (app volume × preamp), ramped across the buffer.
        let targetIn = appGain * (state.enabled ? state.preGain : 1)
        let stepIn = (targetIn - curInGain) * invN
        var g = curInGain
        for n in 0..<frames {
            g += stepIn
            left[n] *= g; right[n] *= g
        }
        curInGain = targetIn

        if state.enabled {
            // 2. EQ cascade, in Double for low-frequency precision.
            for s in 0..<state.sectionCount {
                let c = state.sections[s]
                let zp = z + s * 4
                var z1 = zp[0], z2 = zp[1]
                for n in 0..<frames {
                    let x = Double(left[n])
                    let y = c.b0 * x + z1
                    z1 = c.b1 * x - c.a1 * y + z2
                    z2 = c.b2 * x - c.a2 * y
                    left[n] = Float(y)
                }
                zp[0] = z1; zp[1] = z2
                z1 = zp[2]; z2 = zp[3]
                for n in 0..<frames {
                    let x = Double(right[n])
                    let y = c.b0 * x + z1
                    z1 = c.b1 * x - c.a1 * y + z2
                    z2 = c.b2 * x - c.a2 * y
                    right[n] = Float(y)
                }
                zp[2] = z1; zp[3] = z2
            }

            // 3. Crossfeed.
            if state.crossfeedEnabled {
                let k = state.crossfeed
                for n in 0..<frames {
                    let inL = Double(left[n]), inR = Double(right[n])
                    cfLoL = k.a0Lo * inL + k.b1Lo * cfLoL
                    cfLoR = k.a0Lo * inR + k.b1Lo * cfLoR
                    cfHiL = k.a0Hi * inL + k.a1Hi * cfAsisL + k.b1Hi * cfHiL
                    cfHiR = k.a0Hi * inR + k.a1Hi * cfAsisR + k.b1Hi * cfHiR
                    cfAsisL = inL; cfAsisR = inR
                    left[n] = Float((cfHiL + cfLoR) * k.gain)
                    right[n] = Float((cfHiR + cfLoL) * k.gain)
                }
            }

            // 4. Balance and gain trim.
            let stepL = (state.gainL - curGainL) * invN, stepR = (state.gainR - curGainR) * invN
            var gl = curGainL, gr = curGainR
            for n in 0..<frames {
                gl += stepL; gr += stepR
                left[n] *= gl; right[n] *= gr
            }
            curGainL = state.gainL; curGainR = state.gainR

            // 5. Lookahead peak limiter.
            if state.limiterEnabled { limit(left, right, frames, state) }
        }

        // 6. Software device volume (devices without hardware volume). Always applied.
        let stepS = (state.softwareGain - curSoftware) * invN
        var gs = curSoftware
        var peak: Float = 0
        for n in 0..<frames {
            gs += stepS
            let l = left[n] * gs, r = right[n] * gs
            left[n] = l; right[n] = r
            peak = max(peak, abs(l), abs(r))
        }
        curSoftware = state.softwareGain
        return peak
    }

    private func stateChanged(to state: ChainState) {
        if let last = lastState, last.sampleRate != state.sampleRate { reset() }
        if state.enabled != lastWasEnabled { reset() }
        if state.sectionCount > lastSectionCount {
            // Newly activated sections start from silence.
            let from = lastSectionCount * 4, count = (state.sectionCount - lastSectionCount) * 4
            (z + from).update(repeating: 0, count: count)
        }
        if state.lookahead != lastLookahead {
            delayL.update(repeating: 0, count: Self.maxLookahead)
            delayR.update(repeating: 0, count: Self.maxLookahead)
            delayPos = 0
        }
        if !state.crossfeedEnabled { cfLoL = 0; cfLoR = 0; cfHiL = 0; cfHiR = 0; cfAsisL = 0; cfAsisR = 0 }
        lastState = state
        lastWasEnabled = state.enabled
        lastLookahead = state.lookahead
        lastSectionCount = state.sectionCount
    }

    private func limit(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int, _ state: ChainState) {
        let la = state.lookahead
        let ceiling = state.ceiling
        let release = state.releaseCoeff
        // Reaches ~90% of the target within the lookahead window.
        let attack = 1 - expf(-2.3 / Float(la))
        for n in 0..<frames {
            let inL = left[n], inR = right[n]
            let level = max(abs(inL), abs(inR))
            let required: Float = level > ceiling ? ceiling / level : 1

            // Hold the smallest required gain for the lookahead length.
            if required <= heldGain {
                heldGain = required
                holdCounter = la
            } else if holdCounter > 0 {
                holdCounter -= 1
            } else {
                heldGain = required
            }

            if heldGain < envelope {
                envelope += (heldGain - envelope) * attack
            } else {
                envelope = heldGain + (envelope - heldGain) * release
            }

            // Delay the signal so gain reduction starts before the peak arrives.
            let outL = delayL[delayPos], outR = delayR[delayPos]
            delayL[delayPos] = inL; delayR[delayPos] = inR
            delayPos += 1
            if delayPos >= la { delayPos = 0 }

            // Final safety clamp catches anything the smoothed envelope missed.
            left[n] = max(-ceiling, min(ceiling, outL * envelope))
            right[n] = max(-ceiling, min(ceiling, outR * envelope))
        }
    }
}
