import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Real-time part of a tap session: reads the tap from the aggregate's input, processes it and
/// writes it to the output device. Everything it touches is preallocated.
final class TapRenderer: @unchecked Sendable {
    static let capacity = 8192

    let processor = StreamProcessor()
    let chain: ChainHandle
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let peakBits = Atomic<UInt32>(0)
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    /// Set before IO starts; true when the tap delivers one buffer per channel.
    var tapNonInterleaved = false

    init(chain: ChainHandle) {
        self.chain = chain
        left.initialize(repeating: 0, count: Self.capacity)
        right.initialize(repeating: 0, count: Self.capacity)
    }

    deinit { left.deallocate(); right.deallocate() }

    var gain: Float {
        get { Float(bitPattern: gainBits.load(ordering: .relaxed)) }
        set { gainBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    /// Returns and clears the peak level since the last call.
    func takePeak() -> Float { Float(bitPattern: peakBits.exchange(0, ordering: .relaxed)) }

    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard outs.count > 0 else { return }
        for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }

        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard ins.count > 0 else { return }

        // The tap's stream(s) come after any input streams of the output device itself.
        let last = ins[ins.count - 1]
        guard let lastData = last.mData?.assumingMemoryBound(to: Float.self), last.mNumberChannels > 0 else { return }
        var frames: Int
        if last.mNumberChannels >= 2 {
            let ch = Int(last.mNumberChannels)
            frames = min(Int(last.mDataByteSize) / (4 * ch), Self.capacity)
            for n in 0..<frames {
                left[n] = lastData[n * ch]
                right[n] = lastData[n * ch + 1]
            }
        } else if tapNonInterleaved, ins.count >= 2, let lData = ins[ins.count - 2].mData?.assumingMemoryBound(to: Float.self) {
            frames = min(Int(last.mDataByteSize) / 4, Int(ins[ins.count - 2].mDataByteSize) / 4, Self.capacity)
            for n in 0..<frames {
                left[n] = lData[n]
                right[n] = lastData[n]
            }
        } else {
            frames = min(Int(last.mDataByteSize) / 4, Self.capacity)
            for n in 0..<frames {
                left[n] = lastData[n]
                right[n] = lastData[n]
            }
        }

        // Never write more than the output can hold.
        let out0 = outs[0]
        let outCh = Int(max(1, out0.mNumberChannels))
        frames = min(frames, Int(out0.mDataByteSize) / (4 * outCh))
        guard frames > 0 else { return }

        let peak = processor.process(left: left, right: right, frames: frames, state: chain.current(), appGain: gain)
        let prev = Float(bitPattern: peakBits.load(ordering: .relaxed))
        if peak > prev { peakBits.store(peak.bitPattern, ordering: .relaxed) }

        guard let o0 = out0.mData?.assumingMemoryBound(to: Float.self) else { return }
        if outCh >= 2 {
            for n in 0..<frames {
                o0[n * outCh] = left[n]
                o0[n * outCh + 1] = right[n]
            }
        } else if outs.count >= 2, let o1 = outs[1].mData?.assumingMemoryBound(to: Float.self) {
            let f = min(frames, Int(outs[1].mDataByteSize) / 4)
            for n in 0..<f { o0[n] = left[n]; o1[n] = right[n] }
        } else {
            for n in 0..<frames { o0[n] = 0.5 * (left[n] + right[n]) }
        }
    }
}

/// One app's audio path: a muted process tap feeding a private aggregate device whose main
/// sub-device is the current output. The aggregate's IOProc processes and plays the audio.
///
/// If Alter quits or crashes, the tap is destroyed with the process and the app's audio goes
/// straight to the output device again.
///
/// Not thread-safe: used only on the engine worker queue.
final class TapSession {
    let key: String
    let renderer: TapRenderer
    private(set) var processObjects: [AudioObjectID]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private let tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var deviceUID: String?
    private(set) var isRunning = false

    init(key: String, name: String, processObjects: [AudioObjectID], chain: ChainHandle) throws {
        self.key = key
        self.processObjects = processObjects
        self.renderer = TapRenderer(chain: chain)

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = tapUUID
        description.name = "Alter – \(name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &id), "Create process tap for \(name)")
        tapID = id

        if let format = try? tapID.read(.init(kAudioTapPropertyFormat), default: AudioStreamBasicDescription()) {
            renderer.tapNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        }
    }

    /// Changes which process objects feed this tap (helpers come and go).
    func updateProcesses(_ objects: [AudioObjectID]) {
        guard objects != processObjects, tapID != kAudioObjectUnknown else { return }
        processObjects = objects
        let address = AudioObjectPropertyAddress(kAudioTapPropertyDescription)
        var description: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        var a = address
        guard AudioObjectGetPropertyData(tapID, &a, 0, nil, &size, &description) == noErr,
              let current = description?.takeRetainedValue() else { return }
        current.processes = objects
        var updated: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(current)
        AudioObjectSetPropertyData(tapID, &a, 0, nil, size, &updated)
    }

    /// Routes the tap to `device`, rebuilding the aggregate if the device changed (or always,
    /// with `force`, e.g. after the device's sample rate changed).
    func attach(to device: OutputDevice, force: Bool = false) throws {
        if !force, deviceUID == device.uid, aggregateID != kAudioObjectUnknown { return }
        let wasRunning = isRunning
        detach()

        let uid = "\(OutputEngine.aggregateUIDPrefix).\(tapUUID.uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Alter \(key)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregate), "Create aggregate device")
        aggregateID = aggregate
        deviceUID = device.uid

        let renderer = self.renderer
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            renderer.render(input, output)
        }
        guard status == noErr, let procID else {
            detach()
            throw CoreAudioError.status(status, "Create IOProc")
        }
        ioProcID = procID
        if wasRunning { start() }
    }

    func detach() {
        stop()
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        deviceUID = nil
    }

    func start() {
        guard !isRunning, let ioProcID, aggregateID != kAudioObjectUnknown else { return }
        let status = AudioDeviceStart(aggregateID, ioProcID)
        if status == noErr { isRunning = true } else { NSLog("Alter: AudioDeviceStart failed \(status.fourCharString)") }
    }

    func stop() {
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        isRunning = false
    }

    func invalidate() {
        detach()
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
