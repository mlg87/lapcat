import Foundation
import LapCatSpeech

let version = "0.1.0"
let usage = """
usage: lapcat-dev <command> [args]

commands:
  --version    print version and the linked whisper.cpp system info
  stt-bench    --engine whisper|parakeet [--model <file>] <audio-file>: transcription RTF + transcript
  tap-probe <bundle-id>|--system <seconds> <out-dir> [--voice-processing]
               record mic + system audio, print per-second RMS and file formats
  llm-probe    claude-cli|anthropic-api|local "prompt": one LLM round-trip, raw and parsed
  enhance-demo [--template ID] [--model M]: enhance a canned meeting via the Claude CLI
  templates    list built-in templates and their resource bundle
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--version":
    print("lapcat-dev \(version)")
    print("whisper: \(WhisperInfo.systemInfo)")
case "stt-bench":
    exit(await STTBench.run(Array(args.dropFirst())))
case "tap-probe":
    exit(await TapProbe.run(Array(args.dropFirst())))
case "llm-probe":
    exit(await LLMProbe.run(Array(args.dropFirst())))
case "enhance-demo":
    exit(await EnhanceDemo.run(Array(args.dropFirst())))
case "templates":
    exit(TemplatesCommand.run())
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(args.isEmpty ? 0 : 64)
}
