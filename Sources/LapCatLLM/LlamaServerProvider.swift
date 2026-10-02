import Foundation

/// Local model served by the bundled `llama-server` sidecar over its OpenAI-compatible HTTP API.
/// The server starts on first use, stops after 10 idle minutes, on `shutdown()`, and with this process.
public actor LlamaServerProvider: LLMProvider {
    public nonisolated let id = "local"
    public nonisolated let displayName = "Local"
    public nonisolated let contextBudgetTokens = 24_000

    public static let contextSize = 32_768
    public static let startupTimeout: Duration = .seconds(60)
    public static let idleTimeout: Duration = .seconds(600)

    public nonisolated let ggufURL: URL
    /// `<helpers>/llama/<arch>/llama-server`; nil when no helpers directory could be resolved.
    public nonisolated let serverBinaryURL: URL?
    private let session: URLSession

    private var server: LlamaServerProcess?
    private var launching: Task<LlamaServerProcess, Error>?
    private var activeRequests = 0
    private var idleTask: Task<Void, Never>?

    /// - Parameters:
    ///   - ggufURL: the model file.
    ///   - helpersDirectory: directory containing `llama/<arch>/llama-server`; nil resolves
    ///     `LapCat.app/Contents/Helpers` when bundled, else `<repo>/vendor`.
    public init(ggufURL: URL, helpersDirectory: URL?) {
        self.ggufURL = ggufURL
        serverBinaryURL = (helpersDirectory ?? Self.defaultHelpersDirectory())?
            .appendingPathComponent("llama/\(Self.arch)/llama-server")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration)
    }

    deinit {
        server?.terminate()
    }

    static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    /// `Contents/Helpers` inside the app bundle; unbundled (`swift run`), the `vendor` directory of the
    /// package checkout found above the executable or the working directory.
    public static func defaultHelpersDirectory() -> URL? {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { return bundle.appendingPathComponent("Contents/Helpers") }
        let fm = FileManager.default
        let starts = [Bundle.main.executableURL?.deletingLastPathComponent(), URL(fileURLWithPath: fm.currentDirectoryPath)]
        for start in starts.compactMap({ $0?.standardizedFileURL }) {
            var dir = start
            while dir.path != "/" {
                if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                    return dir.appendingPathComponent("vendor")
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return nil
    }

    public func isAvailable() async -> Bool {
        let fm = FileManager.default
        guard let serverBinaryURL else { return false }
        return fm.fileExists(atPath: ggufURL.path) && fm.isExecutableFile(atPath: serverBinaryURL.path)
    }

    /// Stops the server now; the next request starts it again.
    public func shutdown() {
        idleTask?.cancel()
        idleTask = nil
        launching?.cancel()
        launching = nil
        server?.terminate()
        server = nil
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let port = try await beginRequest()
        defer { endRequest() }
        let urlRequest = try makeRequest(request, port: port, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw normalize(error)
        }
        try Self.check(response, body: data)
        return try Self.parseCompletion(data, model: ggufURL.lastPathComponent)
    }

    public nonisolated func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let port = try await self.beginRequest()
                    do {
                        let bytes = try await self.openStream(request, port: port)
                        loop: for try await line in bytes.lines {
                            switch OpenAISSE.step(line) {
                            case .text(let text): continuation.yield(text)
                            case .done: break loop
                            case .failure(let error): throw error
                            case .ignore: continue
                            }
                        }
                        await self.endRequest()
                        continuation.finish()
                    } catch {
                        await self.endRequest()
                        throw error
                    }
                } catch {
                    continuation.finish(throwing: normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openStream(_ request: LLMRequest, port: Int) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: try makeRequest(request, port: port, stream: true))
        if (response as? HTTPURLResponse).map({ !(200..<300).contains($0.statusCode) }) ?? true {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            try Self.check(response, body: body)
        }
        return bytes
    }

    // MARK: - Server lifecycle

    private func beginRequest() async throws -> Int {
        activeRequests += 1
        idleTask?.cancel()
        idleTask = nil
        do {
            return try await ensureServer().port
        } catch {
            endRequest()
            throw error
        }
    }

    private func endRequest() {
        activeRequests -= 1
        guard activeRequests == 0 else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard activeRequests == 0 else { return }
        shutdown()
    }

    private func ensureServer() async throws -> LlamaServerProcess {
        if let server, server.isRunning { return server }
        server = nil
        if let launching { return try await launching.value }
        guard let binary = serverBinaryURL, FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw LLMError.unavailable("llama-server not found at \(serverBinaryURL?.path ?? "<no helpers directory>")")
        }
        guard FileManager.default.fileExists(atPath: ggufURL.path) else {
            throw LLMError.unavailable("local model not downloaded: \(ggufURL.lastPathComponent)")
        }
        let task = Task { try await Self.launch(binary: binary, gguf: ggufURL, session: session) }
        launching = task
        defer { launching = nil }
        let started = try await task.value
        server = started
        return started
    }

    private static func launch(binary: URL, gguf: URL, session: URLSession) async throws -> LlamaServerProcess {
        let port = try LlamaServerProcess.freePort()
        let process = try LlamaServerProcess(binary: binary, arguments: [
            "-m", gguf.path, "--host", "127.0.0.1", "--port", String(port), "-c", String(contextSize),
            "--jinja", "-np", "1", "--reasoning", "off", "--no-webui", "--offline",
        ], port: port)
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        let deadline = ContinuousClock.now + startupTimeout
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard process.isRunning else {
                    throw LLMError.unavailable("llama-server failed to start: \(process.lastErrorLine)")
                }
                var probe = URLRequest(url: health, timeoutInterval: 2)
                probe.httpMethod = "GET"
                if let (_, response) = try? await session.data(for: probe),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    return process
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw LLMError.unavailable("llama-server failed to start: \(process.lastErrorLine)")
        } catch {
            process.terminate()
            throw normalize(error)
        }
    }

    // MARK: - HTTP

    private func makeRequest(_ request: LLMRequest, port: Int, stream: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        var messages: [[String: String]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": "local",
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": 0.3,
            "stream": stream,
        ]
        if request.expectJSON { body["response_format"] = ["type": "json_object"] }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("not an HTTP response") }
        guard !(200..<300).contains(http.statusCode) else { return }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        // 400 is a request the server rejects (e.g. prompt longer than the context); retrying elsewhere may help.
        throw LLMError.unavailable("llama-server HTTP \(http.statusCode): \(message)")
    }

    /// Parses a non-streaming OpenAI chat completion.
    static func parseCompletion(_ data: Data, model: String) throws -> LLMResponse {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.invalidResponse("llama-server response has no message content")
        }
        let usage = json["usage"] as? [String: Any]
        return LLMResponse(
            text: text,
            provider: "local",
            model: model,
            inputTokens: usage?["prompt_tokens"] as? Int,
            outputTokens: usage?["completion_tokens"] as? Int
        )
    }
}
