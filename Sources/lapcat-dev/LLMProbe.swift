import Foundation
import LapCatLLM

/// `lapcat-dev llm-probe claude-cli|anthropic-api|local [--model M] [--gguf PATH] [--stream] "prompt"`
enum LLMProbe {
    static let usage = """
        usage: lapcat-dev llm-probe claude-cli|anthropic-api|local [options] "prompt"
          --model M     model for claude-cli (default haiku) or anthropic-api (default claude-haiku-4-5)
          --gguf PATH   local model (default ~/Library/Application Support/LapCat/models/Qwen3-4B-Q4_K_M.gguf)
          --stream      print streamed deltas instead of one completion
        anthropic-api reads the key from $ANTHROPIC_API_KEY (probe only).

        """

    static func run(_ arguments: [String]) async -> Int32 {
        var positional: [String] = []
        var model: String?
        var gguf = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LapCat/models/Qwen3-4B-Q4_K_M.gguf")
        var streaming = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--model": model = iterator.next()
            case "--gguf": gguf = URL(fileURLWithPath: ((iterator.next() ?? "") as NSString).expandingTildeInPath)
            case "--stream": streaming = true
            default: positional.append(argument)
            }
        }
        guard positional.count == 2 else {
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }
        let request = LLMRequest(
            task: .classify, system: "You are a terse assistant.", messages: [.user(positional[1])], maxTokens: 256)

        let provider: any LLMProvider
        switch positional[0] {
        case "claude-cli":
            let cli = ClaudeCLIProvider(
                models: Dictionary(uniqueKeysWithValues: LLMTask.allCases.map { ($0, model ?? "haiku") }),
                claudePath: nil)
            guard !streaming else {
                provider = cli
                break
            }
            print("binary: \(cli.binaryURL?.path ?? "not found")")
            do {
                let (envelope, response) = try await cli.completeWithEnvelope(request)
                print("envelope: \(envelope)")
                printResponse(response)
                return 0
            } catch {
                return fail(error)
            }
        case "anthropic-api":
            provider = AnthropicAPIProvider(
                models: Dictionary(uniqueKeysWithValues: LLMTask.allCases.map { ($0, model ?? "claude-haiku-4-5") }),
                apiKey: { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] }
            )
        case "local":
            let local = LlamaServerProvider(ggufURL: gguf, helpersDirectory: nil)
            print("server: \(local.serverBinaryURL?.path ?? "not found")")
            print("model: \(gguf.path)")
            let started = ContinuousClock.now
            let status = await probe(local, request, streaming: streaming)
            print("elapsed (incl. server start): \(ContinuousClock.now - started)")
            await local.shutdown()
            return status
        default:
            FileHandle.standardError.write(Data(usage.utf8))
            return 64
        }
        return await probe(provider, request, streaming: streaming)
    }

    private static func probe(_ provider: any LLMProvider, _ request: LLMRequest, streaming: Bool) async -> Int32 {
        guard await provider.isAvailable() else {
            return fail(LLMError.unavailable("\(provider.displayName) is not available"))
        }
        do {
            if streaming {
                var text = ""
                for try await delta in provider.stream(request) {
                    print("delta: \(String(reflecting: delta))")
                    text += delta
                }
                print("text: \(text)")
            } else {
                printResponse(try await provider.complete(request))
            }
            return 0
        } catch {
            return fail(error)
        }
    }

    private static func printResponse(_ response: LLMResponse) {
        print("provider: \(response.provider)  model: \(response.model)")
        print(
            "tokens in/out: \(response.inputTokens.map(String.init) ?? "-")/\(response.outputTokens.map(String.init) ?? "-")  cost: \(response.costUSD.map { String(format: "$%.4f", $0) } ?? "-")"
        )
        print("text: \(response.text)")
    }

    private static func fail(_ error: any Error) -> Int32 {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        return 1
    }
}
