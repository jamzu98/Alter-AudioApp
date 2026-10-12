import CoreAudio
import Foundation

/// Thin, typed helpers around the AudioObject property C API.
enum CoreAudioError: Error, CustomStringConvertible {
    case status(OSStatus, String)

    var description: String {
        switch self {
        case let .status(code, what):
            return "\(what) failed (\(code.fourCharString))"
        }
    }
}

extension OSStatus {
    var fourCharString: String {
        let n = UInt32(bitPattern: self)
        let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return String(self)
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError.status(status, what()) }
}

extension AudioObjectPropertyAddress {
    init(_ selector: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) {
        self.init(mSelector: selector, mScope: scope, mElement: element)
    }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(self, &a)
    }

    func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(self, &a, &settable) == noErr && settable.boolValue
    }

    func read<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, default value: T) throws -> T {
        var a = address
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, &result), "Get \(address.mSelector)")
        return result
    }

    func readArray<T>(_ address: AudioObjectPropertyAddress, of _: T.Type) throws -> [T] {
        var a = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &a, 0, nil, &size), "Size \(address.mSelector)")
        let count = Int(size) / MemoryLayout<T>.stride
        if count == 0 { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, buffer), "Get \(address.mSelector)")
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ address: AudioObjectPropertyAddress) throws -> String {
        var a = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &a, 0, nil, &size, &value), "Get string \(address.mSelector)")
        guard let value else { return "" }
        return value.takeRetainedValue() as String
    }

    func write<T: BitwiseCopyable>(_ address: AudioObjectPropertyAddress, _ value: T) throws {
        var a = address
        var v = value
        try check(AudioObjectSetPropertyData(self, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v), "Set \(address.mSelector)")
    }

    // MARK: Common properties

    var uid: String? { try? readString(.init(kAudioDevicePropertyDeviceUID)) }
    var name: String? { try? readString(.init(kAudioObjectPropertyName)) }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        (try? readArray(.init(kAudioDevicePropertyStreams, scope), of: AudioStreamID.self).count) ?? 0
    }

    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    var nominalSampleRate: Double {
        (try? read(.init(kAudioDevicePropertyNominalSampleRate), default: Float64(0))) ?? 0
    }

    /// Sample rates the device supports. Continuous ranges are expanded to the standard rates
    /// they contain.
    var availableSampleRates: [Double] {
        guard let ranges = try? readArray(.init(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self) else { return [] }
        let standard: [Double] = [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000,
                                  176_400, 192_000, 352_800, 384_000, 705_600, 768_000]
        var rates = Set<Double>()
        for r in ranges {
            if r.mMaximum - r.mMinimum < 1 {
                rates.insert(r.mMinimum)
            } else {
                standard.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { rates.insert($0) }
            }
        }
        return rates.sorted()
    }
}

/// Owns a property listener block and removes it on deinit.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private let queue: DispatchQueue

    init?(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
