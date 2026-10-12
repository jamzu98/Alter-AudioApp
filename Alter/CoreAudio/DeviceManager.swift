import AudioToolbox
import CoreAudio
import Foundation
import Observation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    /// Sample rates the device supports, ascending.
    let sampleRates: [Double]
    let canSetSampleRate: Bool

    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            let lower = name.lowercased()
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up"
        case kAudioDeviceTransportTypeBuiltIn:
            return name.lowercased().contains("headphone") ? "headphones" : "laptopcomputer"
        default: return "hifispeaker"
        }
    }
}

/// Lists output devices, tracks the system default output and controls its volume.
@MainActor
@Observable
final class DeviceManager {
    private(set) var outputs: [OutputDevice] = []
    private(set) var defaultOutput: OutputDevice?

    /// 0...1 volume of the default output (hardware), or nil if the device has no volume control.
    private(set) var hardwareVolume: Float?
    private(set) var hardwareMuted = false
    /// Volume of the default device in dB, used for loudness compensation.
    private(set) var volumeDecibels: Float = 0
    /// Nominal sample rate of the default output.
    private(set) var sampleRate: Double = 48_000
    /// Current nominal sample rate of every output device, by UID. Kept live by listeners.
    private(set) var currentRates: [String: Double] = [:]

    @ObservationIgnored var onDefaultOutputChanged: ((OutputDevice?) -> Void)?
    /// Volume or sample rate of the default output changed.
    @ObservationIgnored var onDeviceStateChanged: (() -> Void)?
    /// The default output's sample rate changed.
    @ObservationIgnored var onSampleRateChanged: (() -> Void)?
    /// Output devices that appeared since the last device list update.
    @ObservationIgnored var onDevicesConnected: (([OutputDevice]) -> Void)?

    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var deviceListeners: [PropertyListener] = []
    @ObservationIgnored private var rateListeners: [AudioObjectID: PropertyListener] = [:]

    private static let virtualMain = AudioObjectPropertyAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
    private static let muteAddress = AudioObjectPropertyAddress(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    init() {
        reloadDevices()
        reloadDefault()
        let sys = AudioObjectID.system
        systemListeners = [
            PropertyListener(object: sys, address: .init(kAudioHardwarePropertyDevices)) { [weak self] in
                self?.reloadDevices()
                self?.reloadDefault()
            },
            PropertyListener(object: sys, address: .init(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                self?.reloadDefault()
            },
        ].compactMap { $0 }
    }

    // MARK: Device list

    private func reloadDevices() {
        let ids = (try? AudioObjectID.system.readArray(.init(kAudioHardwarePropertyDevices), of: AudioObjectID.self)) ?? []
        let list = ids.compactMap { id -> OutputDevice? in
            guard id.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0,
                  let uid = id.uid, !uid.hasPrefix(OutputEngine.aggregateUIDPrefix),
                  !uid.hasPrefix("CADefaultDeviceAggregate")
            else { return nil }
            let hidden = (try? id.read(.init(kAudioDevicePropertyIsHidden), default: UInt32(0))) ?? 0
            if hidden != 0 { return nil }
            let transport = (try? id.read(.init(kAudioDevicePropertyTransportType), default: UInt32(0))) ?? 0
            let name = (id.name ?? uid).trimmingCharacters(in: .whitespacesAndNewlines)
            return OutputDevice(id: id, uid: uid, name: name, transport: transport,
                                sampleRates: id.availableSampleRates,
                                canSetSampleRate: id.isSettable(.init(kAudioDevicePropertyNominalSampleRate)))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let previous = Set(outputs.map(\.uid))
        outputs = list
        observeRates()
        let connected = list.filter { !previous.contains($0.uid) }
        if !connected.isEmpty { onDevicesConnected?(connected) }
    }

    private func observeRates() {
        let ids = Set(outputs.map(\.id))
        rateListeners = rateListeners.filter { ids.contains($0.key) }
        for device in outputs where rateListeners[device.id] == nil {
            let id = device.id, uid = device.uid
            rateListeners[id] = PropertyListener(object: id, address: .init(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
                self?.currentRates[uid] = id.nominalSampleRate
            }
        }
        currentRates = Dictionary(outputs.map { ($0.uid, $0.id.nominalSampleRate) }, uniquingKeysWith: { a, _ in a })
    }

    /// Sets a device's nominal sample rate. Returns false if the device refused it.
    @discardableResult
    func setSampleRate(_ rate: Double, for device: OutputDevice) -> Bool {
        guard device.canSetSampleRate, device.sampleRates.contains(rate) else { return false }
        guard abs(device.id.nominalSampleRate - rate) > 0.5 else { return true }
        do {
            try device.id.write(.init(kAudioDevicePropertyNominalSampleRate), Float64(rate))
            return true
        } catch {
            NSLog("Alter: could not set \(device.name) to \(rate) Hz: \(error)")
            return false
        }
    }

    private func reloadDefault() {
        let id = (try? AudioObjectID.system.read(.init(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(0))) ?? 0
        let device = outputs.first { $0.id == id }
        let changed = device?.uid != defaultOutput?.uid || device?.id != defaultOutput?.id
        defaultOutput = device
        if changed {
            observeDevice(id)
            onDefaultOutputChanged?(device)
        }
    }

    func setDefaultOutput(_ device: OutputDevice) {
        do {
            try AudioObjectID.system.write(.init(kAudioHardwarePropertyDefaultOutputDevice), device.id)
            // Keep alerts and sound effects on the same device.
            let sysOut = AudioObjectPropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
            if AudioObjectID.system.isSettable(sysOut) {
                try? AudioObjectID.system.write(sysOut, device.id)
            }
        } catch {
            NSLog("Alter: could not set default output: \(error)")
        }
    }

    // MARK: Volume & sample rate

    private func observeDevice(_ id: AudioObjectID) {
        deviceListeners = []
        guard id != 0 else { hardwareVolume = nil; return }
        let addresses: [AudioObjectPropertyAddress] = [
            Self.virtualMain,
            .init(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput),
            .init(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1),
            Self.muteAddress,
        ]
        deviceListeners = addresses.compactMap { address in
            guard id.hasProperty(address) else { return nil }
            return PropertyListener(object: id, address: address) { [weak self] in self?.reloadVolume() }
        }
        if let listener = PropertyListener(object: id, address: .init(kAudioDevicePropertyNominalSampleRate), handler: { [weak self] in
            self?.reloadSampleRate()
        }) {
            deviceListeners.append(listener)
        }
        reloadSampleRate()
        reloadVolume()
    }

    private func reloadSampleRate() {
        guard let id = defaultOutput?.id else { return }
        let rate = id.nominalSampleRate
        if rate > 0, rate != sampleRate {
            sampleRate = rate
            onDeviceStateChanged?()
            onSampleRateChanged?()
        }
    }

    private func reloadVolume() {
        guard let id = defaultOutput?.id else { hardwareVolume = nil; return }
        let scalar0 = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
        let scalar1 = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1)
        if id.hasProperty(Self.virtualMain), let v = try? id.read(Self.virtualMain, default: Float32(0)) {
            hardwareVolume = v
        } else if id.hasProperty(scalar0), let v = try? id.read(scalar0, default: Float32(0)) {
            hardwareVolume = v
        } else if id.hasProperty(scalar1), let v = try? id.read(scalar1, default: Float32(0)) {
            hardwareVolume = v
        } else {
            hardwareVolume = nil
        }
        hardwareMuted = ((try? id.read(Self.muteAddress, default: UInt32(0))) ?? 0) != 0

        let db0 = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput)
        let db1 = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, 1)
        if id.hasProperty(db0), let db = try? id.read(db0, default: Float32(0)) {
            volumeDecibels = db
        } else if id.hasProperty(db1), let db = try? id.read(db1, default: Float32(0)) {
            volumeDecibels = db
        } else if let v = hardwareVolume {
            // Approximate a typical 0...-60 dB taper when the device does not report dB.
            volumeDecibels = v > 0.0001 ? 60 * (v - 1) : -60
        } else {
            volumeDecibels = 0
        }
        onDeviceStateChanged?()
    }

    func setVolume(_ value: Float) {
        guard let id = defaultOutput?.id else { return }
        let v = max(0, min(1, value))
        if id.isSettable(Self.virtualMain) {
            try? id.write(Self.virtualMain, v)
        } else {
            for element: UInt32 in [0, 1, 2] {
                let a = AudioObjectPropertyAddress(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
                if id.isSettable(a) { try? id.write(a, v) }
            }
        }
        hardwareVolume = v
        if hardwareMuted && v > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard let id = defaultOutput?.id else { return }
        if id.isSettable(Self.muteAddress) {
            try? id.write(Self.muteAddress, UInt32(muted ? 1 : 0))
        }
        hardwareMuted = muted
        onDeviceStateChanged?()
    }

    var supportsHardwareMute: Bool {
        guard let id = defaultOutput?.id else { return false }
        return id.isSettable(Self.muteAddress)
    }
}
