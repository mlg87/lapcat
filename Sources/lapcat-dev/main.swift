import Foundation
import LapCatSpeech

let version = "0.1.0"
let usage = """
usage: lapcat-dev <command> [args]

commands:
  --version    print version and the linked whisper.cpp system info
  llm-probe    claude-cli|anthropic-api|local "prompt": one LLM round-trip, raw and parsed
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--version":
    print("lapcat-dev \(version)")
    print("whisper: \(WhisperInfo.systemInfo)")
case "llm-probe":
    exit(await LLMProbe.run(Array(args.dropFirst())))
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(args.isEmpty ? 0 : 64)
}
