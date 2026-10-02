import Foundation

/// Process-wide setup that must happen before the first whisper.cpp / ggml call.
public enum WhisperRuntime {
    /// On Intel Macs, hides Metal devices from ggml so whisper runs CPU-only.
    ///
    /// `use_gpu = false` alone is not enough: ggml's backend registry still initialises the Metal
    /// device on first use, which compiles the embedded shader source with `newLibraryWithSource`.
    /// On Intel/AMD GPUs that compile ran for over an hour in the soak test and blocked every
    /// model load behind it. `GGML_METAL_DEVICES=0` makes the registry expose no Metal device.
    /// The registry reads the variable once, so this runs before any ggml call; an existing value
    /// (set by the user) is kept.
    public static func configure() {
        #if arch(x86_64)
        setenv("GGML_METAL_DEVICES", "0", 0)
        #endif
    }
}
