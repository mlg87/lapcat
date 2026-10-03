# Changelog

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
