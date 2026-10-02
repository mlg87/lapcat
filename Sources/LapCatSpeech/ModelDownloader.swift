import CryptoKit
import Foundation
import os

public enum ModelError: Error, Equatable, CustomStringConvertible {
    /// `llm.offlineOnly` is on: no network access allowed.
    case offlineMode
    case unknownModel(String)
    case http(Int)
    case incomplete(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case io(String)

    public var description: String {
        switch self {
        case .offlineMode: "offline-only mode is on; model downloads are disabled"
        case .unknownModel(let id): "unknown model \(id)"
        case .http(let status): "download failed with HTTP \(status)"
        case .incomplete(let expected, let actual): "download incomplete: \(actual) of \(expected) bytes"
        case .checksumMismatch(let expected, let actual): "checksum mismatch: expected \(expected), got \(actual)"
        case .io(let reason): "model file I/O failed: \(reason)"
        }
    }
}

/// Downloads catalog models into `modelsDirectory` via `<file>.partial`, resuming an interrupted
/// download with an HTTP `Range` request and verifying size + SHA-256 before the final rename.
public struct ModelDownloader: Sendable {
    public let modelsDirectory: URL
    public let offlineOnly: Bool

    public init(modelsDirectory: URL, offlineOnly: Bool) {
        self.modelsDirectory = modelsDirectory
        self.offlineOnly = offlineOnly
    }

    public func fileURL(for id: String) -> URL {
        modelsDirectory.appending(path: id, directoryHint: .notDirectory)
    }

    public func isAvailable(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }

    /// Downloads `id` unless already present; `progress` receives 0…1. Returns the final file URL.
    @discardableResult
    public func download(_ id: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard let entry = ModelCatalog.entry(id: id) else { throw ModelError.unknownModel(id) }
        let destination = fileURL(for: id)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard !offlineOnly else { throw ModelError.offlineMode }

        let partial = destination.appendingPathExtension("partial")
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        } catch {
            throw ModelError.io(error.localizedDescription)
        }
        if Self.size(of: partial) < entry.sizeBytes {
            try await Self.transfer(entry: entry, to: partial, progress: progress)
        }
        let actual = Self.size(of: partial)
        guard actual == entry.sizeBytes else {
            if actual > entry.sizeBytes { try? FileManager.default.removeItem(at: partial) }
            throw ModelError.incomplete(expected: entry.sizeBytes, actual: actual)
        }
        if let expected = entry.sha256 {
            let digest = try Self.sha256(of: partial)
            guard digest == expected else {
                try? FileManager.default.removeItem(at: partial)
                throw ModelError.checksumMismatch(expected: expected, actual: digest)
            }
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            throw ModelError.io(error.localizedDescription)
        }
        progress(1)
        return destination
    }

    private static func transfer(entry: ModelEntry, to partial: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let existing = size(of: partial)
        var request = URLRequest(url: entry.url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let delegate = DownloadDelegate(partial: partial, existingBytes: existing, expectedTotal: entry.sizeBytes, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setContinuation(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func sha256(of url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw ModelError.io(error.localizedDescription)
        }
    }
}

/// Streams response bytes straight into the `.partial` file (append on 206, truncate on 200).
private final class DownloadDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var handle: FileHandle?
        var written: Int64 = 0
        var failure: Error?
    }

    private let partial: URL
    private let existingBytes: Int64
    private let expectedTotal: Int64
    private let progress: @Sendable (Double) -> Void
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(partial: URL, existingBytes: Int64, expectedTotal: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.partial = partial
        self.existingBytes = existingBytes
        self.expectedTotal = expectedTotal
        self.progress = progress
    }

    func setContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        state.withLock { $0.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle: FileHandle
            let base: Int64
            switch status {
            case 206 where existingBytes > 0:
                handle = try FileHandle(forWritingTo: partial)
                try handle.seekToEnd()
                base = existingBytes
            case 200:
                FileManager.default.createFile(atPath: partial.path, contents: nil)
                handle = try FileHandle(forWritingTo: partial)
                try handle.truncate(atOffset: 0)
                base = 0
            default:
                throw ModelError.http(status)
            }
            state.withLock {
                $0.handle = handle
                $0.written = base
            }
            completionHandler(.allow)
        } catch {
            state.withLock { $0.failure = error as? ModelError ?? ModelError.io(error.localizedDescription) }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let fraction: Double? = state.withLock { state in
            guard let handle = state.handle else { return nil }
            do {
                try handle.write(contentsOf: data)
            } catch {
                state.failure = ModelError.io(error.localizedDescription)
                dataTask.cancel()
                return nil
            }
            state.written += Int64(data.count)
            return Double(state.written) / Double(max(expectedTotal, 1))
        }
        if let fraction { progress(min(fraction, 1)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, failure) = state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
            defer { state.continuation = nil }
            return (state.continuation, state.failure ?? error)
        }
        if let failure {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
