import whisper

public enum WhisperInfo {
    /// whisper.cpp's compiled feature line (CPU/Metal backends, SIMD flags).
    public static var systemInfo: String {
        WhisperRuntime.configure()
        return String(cString: whisper_print_system_info())
    }
}
