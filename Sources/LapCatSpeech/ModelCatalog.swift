import Foundation

/// A downloadable model file. `id` is the file name, which is what settings store
/// (`stt.whisperLiveModel`, `llm.model.local.*`). Parakeet / diarizer models are not listed:
/// FluidAudio downloads those into its own cache.
public struct ModelEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case whisper, gguf }

    public let id: String
    public let displayName: String
    public let url: URL
    /// Lowercase hex SHA-256 of the whole file (Hugging Face LFS oid), verified after download.
    public let sha256: String?
    public let sizeBytes: Int64
    public let kind: Kind

    public var fileName: String { id }
}

public enum ModelCatalog {
    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    // Sizes and sha256 pinned from the Hugging Face `x-linked-size` / `x-linked-etag` headers (2026-10-01).
    public static let all: [ModelEntry] = [
        ModelEntry(
            id: "ggml-base.en.bin", displayName: "Whisper base.en",
            url: URL(string: whisperBase + "ggml-base.en.bin")!,
            sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
            sizeBytes: 147_964_211, kind: .whisper
        ),
        ModelEntry(
            id: "ggml-small.en.bin", displayName: "Whisper small.en",
            url: URL(string: whisperBase + "ggml-small.en.bin")!,
            sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
            sizeBytes: 487_614_201, kind: .whisper
        ),
        ModelEntry(
            id: "ggml-large-v3-turbo-q5_0.bin", displayName: "Whisper large-v3-turbo (q5_0)",
            url: URL(string: whisperBase + "ggml-large-v3-turbo-q5_0.bin")!,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            sizeBytes: 574_041_195, kind: .whisper
        ),
        ModelEntry(
            id: "Qwen3-4B-Q4_K_M.gguf", displayName: "Qwen3 4B (Q4_K_M)",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf")!,
            sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
            sizeBytes: 2_497_280_256, kind: .gguf
        ),
    ]

    public static func entry(id: String) -> ModelEntry? {
        all.first { $0.id == id }
    }
}
