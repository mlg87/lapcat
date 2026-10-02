import Foundation
import LapCatSpeech

let version = "0.1.0"
let usage = """
usage: lapcat-dev <command> [args]

commands:
  --version    print version and the linked whisper.cpp system info
"""

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--version":
    print("lapcat-dev \(version)")
    print("whisper: \(WhisperInfo.systemInfo)")
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(args.isEmpty ? 0 : 64)
}
