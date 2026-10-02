import Foundation
import LapCatSpeech

let version = "0.1.0"
let usage = """
usage: lapcat-dev <command> [args]

commands:
  --version    print version and the linked whisper.cpp system info
  tap-probe <bundle-id>|--system <seconds> <out-dir> [--voice-processing]
               record mic + system audio, print per-second RMS and file formats
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--version":
    print("lapcat-dev \(version)")
    print("whisper: \(WhisperInfo.systemInfo)")
case "tap-probe":
    exit(await TapProbe.run(Array(args.dropFirst())))
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(args.isEmpty ? 0 : 64)
}
