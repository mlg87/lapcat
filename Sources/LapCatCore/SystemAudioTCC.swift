import Foundation

/// Preflight and request for the System Audio Recording permission (`kTCCServiceAudioCapture`).
///
/// macOS has no public API for this permission, and an app only appears under
/// System Settings → Privacy & Security → Screen & System Audio Recording →
/// "System Audio Recording Only" after it has requested it. So this calls the private TCC
/// functions, loaded at runtime, the same way insidegui/AudioCap does. If the symbols are
/// missing (a future macOS), callers fall back to opening System Settings.
enum SystemAudioTCC {
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn =
        @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private nonisolated(unsafe) static let handle = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW
    )

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    /// `nil` when the SPI is unavailable.
    static func preflight() -> PermissionStatus? {
        guard let fn = symbol("TCCAccessPreflight", as: PreflightFn.self) else { return nil }
        switch fn(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt (first time only) and registers LapCat in System Settings.
    /// `nil` when the SPI is unavailable.
    static func request() async -> Bool? {
        guard let fn = symbol("TCCAccessRequest", as: RequestFn.self) else { return nil }
        return await withCheckedContinuation { continuation in
            fn(service, nil) { granted in continuation.resume(returning: granted) }
        }
    }
}
