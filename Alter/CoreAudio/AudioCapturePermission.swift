import AppKit
import Observation

/// Status of the "System Audio Recording" (kTCCServiceAudioCapture) permission that process taps need.
///
/// There is no public API to query it, so this looks up TCC's preflight/request calls at runtime.
/// If the symbols are missing we fall back to `.unknown` and let Core Audio prompt on first use.
@MainActor
@Observable
final class AudioCapturePermission {
    enum Status { case unknown, authorized, denied }

    private(set) var status: Status = .unknown

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: Preflight? = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
    private static let request: Request? = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }

    init() { refresh() }

    func refresh() {
        guard let preflight = Self.preflight else { status = .unknown; return }
        switch preflight(Self.service, nil) {
        case 0: status = .authorized
        case 1: status = .denied
        default: status = .unknown
        }
    }

    /// Asks the user (shows the system prompt once). Calls back on the main queue.
    func request(_ completion: @escaping (Bool) -> Void) {
        guard let request = Self.request else { completion(true); return }
        request(Self.service, nil) { granted in
            DispatchQueue.main.async {
                self.status = granted ? .authorized : .denied
                completion(granted)
            }
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

