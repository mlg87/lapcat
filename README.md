<p align="center">
  <img src="docs/design/readme-header.png" alt="LapCat — a macOS menu-bar meeting notetaker" width="100%">
</p>

LapCat is a macOS menu-bar meeting notetaker: it records your mic and the meeting app's
audio as two channels (no bot), transcribes on-device, and enhances your notes with an LLM.
See [docs/product-requirements/lapcat-mvp-prd.md](docs/product-requirements/lapcat-mvp-prd.md).

## Using LapCat

- **Record:** ⌃⌥N (or the menu-bar cat → New Note) starts a note. ⌃⌥P pauses or resumes, ⌃⌥E ends, ⌃⌥L opens the main window. All four can be rebound in Settings → General.
- **Detection:** when Zoom or a browser starts using the microphone, or a calendar event with a Zoom/Meet link starts, LapCat asks "Record …?". It never records without that click. A session started from the prompt stops on its own 60 s after the app stops using the mic.
- **While recording:** write rough Markdown notes on the left; the live transcript is on the right ("Me" = your mic, "Them" = the meeting app).
- **After End:** LapCat re-transcribes both channels, separates speakers, names them from Zoom/Meet when it can, and writes enhanced notes from a template. A quick version from the live transcript comes first, then the final one. Every AI bullet cites the transcript (`[[s:ID]]`) and links to it.
- **Recall:** search the sidebar; chat with one meeting (Chat tab) or across all of them (menu → Ask across meetings…). Type `/` in chat for recipes such as `/follow-up`.
- **Organize and export:** folders, tags, stars and filters in the sidebar. Export ▾ copies or saves the notes, the whole meeting (`.md`), or the transcript (md/txt/srt/vtt). Settings → Export can write each finished meeting to a folder automatically.
- **LLM providers**, tried in this order (Settings → AI): the Claude CLI you are already signed in to, then an Anthropic API key (stored in the Keychain), then a local Qwen3-4B through the bundled `llama-server`. "Offline only" uses just the local model and blocks all downloads.

Data lives in `~/Library/Application Support/LapCat/`: `lapcat.sqlite`, `audio/<meeting>/{mic,them}.aac` (ADTS AAC, which stays playable after a crash), `models/`, and `templates/` (your own `.md` templates). How long audio is kept is set in Settings → Audio.

### Platform notes

- Intel Macs transcribe with whisper.cpp (`small.en` live and final). Parakeet (FluidAudio Core ML) crashes on x86_64, so Intel never selects it.
- Apple Silicon uses Parakeet by default.
- Zoom/Meet speaker naming reads their accessibility trees. The selectors are editable JSON in Settings → Speakers; `swift run lapcat-dev axdump us.zoom.xos` shows what an app exposes.

## Development

Requirements: macOS 14.2+, Swift 6.2 (Command Line Tools are enough; Xcode is optional).
The project is a single SwiftPM package — there is no `.xcodeproj`.

```bash
scripts/make-dev-cert.sh     # once: self-signed "LapCat Dev" identity in its own keychain
scripts/fetch-sidecars.sh    # once: llama-server binaries for the local LLM (vendor/)
scripts/dev.sh               # build build/LapCat.app (debug), sign it, run it in the foreground
scripts/test.sh              # run the test suites (use this, not bare `swift test`)
scripts/bundle-app.sh release  # Universal 2 (arm64 + x86_64) app bundle
swift run lapcat-dev --help  # developer CLI (probes and benchmarks)
swift scripts/make-icons.swift  # regenerate AppIcon.icns + menu-bar glyph from docs/design/app-icon/
```

`lapcat-dev` commands: `tap-probe` (capture check), `stt-bench` (transcription speed),
`diarize-bench`, `llm-probe claude-cli|anthropic-api|local`, `enhance-demo`, `templates`,
`axdump`, `detect-watch`.

Package layout: `LapCatCore` (GRDB store, settings, permissions, export, citations), `LapCatAudio`
(process tap, mic, ScreenCaptureKit fallback, VAD, input detection), `LapCatSpeech` (whisper.cpp,
Parakeet, diarization, speaker naming), `LapCatLLM` (providers, router, Enhancer, chat),
`LapCatSpeakers` (Zoom/Meet accessibility adapters), `LapCatApp` (SwiftUI menu-bar app).

The app only runs from its signed bundle: macOS privacy grants (microphone, system audio,
accessibility) are keyed to the bundle's signature, and the stable "LapCat Dev" identity keeps
them across rebuilds. Set `LAPCAT_CODESIGN_IDENTITY` to sign with a different identity.

`scripts/test.sh` exists because the Command Line Tools keep `Testing.framework` off the default
search path: a bare `swift test` builds fine but silently runs zero tests.
