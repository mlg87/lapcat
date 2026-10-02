import whisper

public enum WhisperInfo {
    /// whisper.cpp's compiled feature line (CPU/Metal backends, SIMD flags).
    public static var systemInfo: String {
        String(cString: whisper_print_system_info())
    }
}
