# Changelog

## [0.1.1](https://github.com/mlg87/lapcat/compare/v0.1.0...v0.1.1) (2026-10-03)


### Documentation

* require worktrees, conventional commits and STE prose in AGENTS.md ([#43](https://github.com/mlg87/lapcat/issues/43)) ([54da3e2](https://github.com/mlg87/lapcat/commit/54da3e2cb070afab08da64c6727ba7c211e93064))
* rewrite the README for users and contributors ([#45](https://github.com/mlg87/lapcat/issues/45)) ([181e3ea](https://github.com/mlg87/lapcat/commit/181e3ea18a16b46ca295293aa7db55821216cf32)), closes [#39](https://github.com/mlg87/lapcat/issues/39)

## [0.1.0](https://github.com/mlg87/lapcat/releases/tag/v0.1.0) (2026-10-03)

This is the first release of LapCat. LapCat is a meeting notetaker for the macOS menu bar.

### Features

* **Recording and detection:** LapCat records your microphone and the meeting app as two channels. It asks to record when it detects a meeting.
* **Live transcript:** LapCat transcribes both channels on your Mac during the meeting. It shows "Me" and "Them" bubbles next to your Markdown notes.
* **Speaker names:** LapCat separates speakers and names them from Zoom or Google Meet and calendar attendees. The LLM suggests names that you confirm or dismiss.
* **Enhanced notes and templates:** An LLM writes notes from six built-in templates or your own Markdown templates. Each AI bullet cites the transcript.
* **Chat and recipes:** You can ask questions about one meeting or many meetings. Slash recipes such as `/follow-up` and `/actions` give answers with citations.
* **Transcript viewer and export:** The transcript plays audio from each timestamp and accepts edits. Export writes Markdown, plain text, SRT or WebVTT files.
* **Organization and search:** Full-text search finds notes, transcripts, titles and participants. Folders, tags, stars and filters organize the meeting list.
* **Settings:** Nine settings tabs control shortcuts, audio, transcription engines, LLM providers, speakers, detection, templates, recipes and automatic export.
* **Developer CLI:** `lapcat-dev` runs transcription, audio capture, LLM, diarization, accessibility and detection probes for development.
