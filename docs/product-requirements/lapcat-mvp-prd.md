# LapCat MVP — Product Requirements Document

LapCat should be a native Swift/SwiftUI menu-bar app for macOS 14.2+, shipped as a single Universal binary. It captures your microphone and the meeting app's audio as two separate local streams, with no bot joining the call, and labels them "Me" and "Them". It then names the other speakers using Zoom's and Meet's own active-speaker UI, transcribes on-device, and turns your rough notes into Granola-style enhanced notes. The default LLM is Claude, called through your own signed-in Claude Code CLI. A Claude API key and a small local Qwen-class model via llama.cpp are the fallbacks.

## TL;DR

- **Build a Granola-parity personal tool, not a Granola clone.** Keep the parts that make Granola valuable: bot-free capture, a live transcript, your notes plus AI enhancement, templates, recipes, chat, search and the full transcript. Drop accounts, sharing, team spaces, CRM integrations and mobile. LapCat can go past Granola in three places: it keeps data local, it captures per app instead of all system audio, and it lets you edit transcripts.
- **Speech stack splits by chip.** On Apple Silicon, use Parakeet TDT via FluidAudio (Core ML / Neural Engine) for transcription and diarization. On Intel, use whisper.cpp for transcription and sherpa-onnx for diarization, because FluidAudio's Core ML path is Apple-Silicon-oriented. Speaker names come from three layers: the mic/system channel split, Zoom/Meet active-speaker data read through macOS Accessibility (the same approach Granola uses), and calendar attendee names.
- **AI: Claude first, local fallback.** The cleanest use of your Anthropic subscription is to shell out to the unmodified, signed-in `claude` CLI (`claude -p`). Keep an API-key path (Claude Haiku 4.5, $1/$5 per million tokens, 200K context) as the reliable fallback, and Qwen3-4B (Q4) via llama.cpp as the offline option. "Jev" turned out to be TypeSafe AI's hosted, non-generative "System One" decision model. It can't summarize and can't run locally, so it is out of the MVP. It could be added later for classification tasks like picking a template automatically.

---

## 1. Overview & Problem Statement

**Problem.** I'm in back-to-back Zoom and Google Meet calls. I want Granola's workflow: jot a few bullets, then get structured, accurate notes, a searchable full transcript, and who said what. I don't want a bot in the call, and I don't want to pay for a team SaaS, upload my meetings to a vendor cloud, or live with Granola's free-tier history limits.

**What Granola does that we're copying.** Granola is a desktop AI notepad. It listens to your computer's audio in the background, with no bot joining the call, and turns your rough notes into structured summaries when the meeting ends. You type a few shorthand bullets during the call, and the AI expands them using the live transcript.\[1\] That "your notes, enhanced" model is the core idea. Generic auto-summaries are not.

**Product vision.** LapCat is a private, local-first, single-user Granola for Mac. It records only when I say so, keeps everything in a local SQLite database, and treats the transcript as a first-class artifact I can read, search, edit and export.

### Goals (MVP)
1. Capture Zoom (desktop app) and Google Meet (browser) meetings with no bot, reliably separating me from the other side.
2. Live transcript during the meeting; final, higher-accuracy transcript within ~2 minutes after the meeting ends, on both Intel and Apple Silicon.
3. Speaker attribution: "Me" always correct; remote speakers named where Zoom/Meet expose active-speaker info, otherwise clustered as "Speaker 1/2/…" and renameable.
4. Notepad plus one-click "Enhance" that merges my notes with transcript context, shaped by templates.
5. Full transcript viewer, full-text search across all meetings, Markdown export/copy.
6. Works with the Anthropic subscription, an API key, or fully offline with a local model.

### Non-Goals (explicit)
- Authentication, accounts, login, user management.
- Distribution: notarization for public release, auto-update, App Store, installers, licensing, telemetry.
- Multi-user, sharing links, team spaces/shared folders, workspace recipes, admin controls, SSO.
- Team integrations (Slack, Notion, HubSpot/Salesforce/Affinity CRM, Zapier), public API, MCP server (MCP is a v2 candidate, see roadmap).
- Windows, Linux, iOS, Android, web.
- Microsoft Teams/Webex/FaceTime-specific speaker tagging (generic capture will still work).
- Video recording, screen capture, in-meeting live coaching, pre-meeting "Briefs".
- Importing pre-recorded audio files (deferred; cheap to add later).

---

## 2. User Persona

**"Me" — the sole user and developer.**
- Knowledge worker with many Zoom and Google Meet calls daily; uses a Google (or Microsoft) calendar.
- Owns at least one Mac. Hardware could be Intel or Apple Silicon, so both must work. Intel Macs can only run up to macOS 26 Tahoe, and per TechRadar's report of Apple's WWDC Platforms State of the Union only four Intel models run it: the 16-inch MacBook Pro (2019), the four-port 13-inch MacBook Pro (2020), the Mac Pro (2019) and the 27-inch iMac (2020). So an Intel machine may well be on macOS 14 Sonoma or 15 Sequoia.
- Has a Claude Pro/Max subscription and Claude Code installed; comfortable with Xcode and the terminal.
- Values privacy, speed, and owning data; tolerates rough UI edges but not lost meetings.
- Types sparse shorthand during calls and wants the AI to fill in the rest, accurately and in my voice.

---

## 3. Granola Research Summary (what "parity" means in late 2026)

| Area | Granola behavior (late 2026) |
|---|---|
| Capture | No meeting bot. Runs on your computer using system audio plus microphone. Granola "cannot isolate audio from individual applications"; it captures the combined system stream, so music or other audio gets transcribed too. Live meetings only; no importing MP3s.\[2\] |
| Starting | Not fully automatic. You open the calendar-linked note, click a notification, or create a New Note. A note opened before a scheduled meeting can start transcribing at the scheduled time. You must click End, or it may keep transcribing.\[3\]\[4\] |
| Transcript UI | Chat-bubble style: grey (left) = system audio/others, green (right) = your microphone. Transcripts can't be edited ("not currently possible to edit transcripts").\[2\]\[5\] |
| Speakers | Default labels are **Me** (mic) and **Them** (system audio). "Speaker tags" add display names for Zoom, Google Meet and Microsoft Teams on macOS/Windows. They work by reading the meeting app's participant names and active-speaker indicator via macOS Accessibility (Zoom desktop, Teams desktop, Meet in Chrome) or a Chrome extension (Meet). Names only apply live, not to older transcripts. Can't separate several people on one room device, or overlapping speech.\[6\] Mobile apps do acoustic diarization for in-person meetings.\[7\] |
| Notes | Notion-style editor. Type during the meeting, then "Enhance notes" merges your bullets with the transcript into structured notes with action items, decisions and quotes.\[8\] |
| Templates | Built-in templates (one review counts 29, e.g. 1:1, stand-up, discovery call),\[8\] "Auto" selection, and custom templates.\[9\] |
| Recipes | Reusable saved prompts invoked with "/" in the chat bar. They are static: no variables or placeholders. There's a Discover library, My recipes and Workspace recipes.\[10\] |
| Chat | "Ask Granola" / Granola Chat over a single note, a folder, or all meetings, with inline citations back to the source meeting. Rebuilt as agentic in 2026; can also do web research.\[11\]\[12\]\[13\] |
| Organization | Spaces (private "My notes" plus a domain-wide Team space) containing folders. Starring. Search across notes, people and companies.\[14\]\[15\] |
| Calendar | Google and Microsoft calendar sync creates notes for upcoming events and sends notifications. |
| Sharing/export | Share links, sending to attendees, copy/paste (e.g. into Slack); a CSV export option.\[16\] |
| Integrations | Notion, Slack, HubSpot, Zapier (Business tier); Salesforce (Enterprise); MCP server (since February 2026); personal REST API (Business+, March 2026).\[17\]\[18\] |
| Privacy | Desktop doesn't store audio: it's transcribed in real time and deleted. Audio is sent to a cloud transcription subprocessor, so it isn't fully local. Notes and transcripts are kept in Granola's cloud indefinitely unless deleted.\[19\]\[20\] Granola doesn't automatically notify participants; consent is the user's job. Optional "Heads Up" calendar add-on and Enterprise notices exist.\[15\]\[21\]\[22\] Local cache encrypted in 2026.\[18\] |
| Platforms | macOS, Windows, iOS, Android.\[23\] |
| Pricing | Basic (free), Business $14/user/mo, Enterprise from $35/user/mo. Granola's "Subscriptions and billing" help page lists Basic note history as "Last 30 days only in the app": older notes "are stored (not deleted), but they aren't accessible in the app until you upgrade," with "No daily limit" on transcriptions. Some reviewers' claim of a 25-note cap doesn't match this. |

**Core vs. nice-to-have judgment.** For one user, Granola's real value is concentrated in five things: (1) bot-free capture, (2) Me/Them plus named speakers, (3) the notes-plus-transcript "Enhance" step, (4) templates, recipes and chat over your history, (5) search and recall. Almost everything on the paid tiers (integrations, API, SSO, admin, shared spaces) is team distribution plumbing, which this MVP doesn't need.

---

## 4. Granola Feature-Parity Matrix

| # | Feature | Granola behavior | MVP | Rationale |
|---|---|---|---|---|
| 1 | Bot-free capture | System audio + mic on device | **Include** | Core value. |
| 2 | Per-app capture | Not supported (combined stream) | **Include (improvement)** | Core Audio process taps can tap only Zoom or Chrome, so Spotify isn't transcribed.\[24\]\[25\] |
| 3 | Calendar sync | Google/Microsoft; notes per event | **Include (EventKit)** | Use macOS Calendar (EventKit), which already syncs Google/Microsoft accounts. No OAuth needed. |
| 4 | Meeting auto-detect + prompt | Notification; scheduled auto-start | **Include** | Prompt when the mic goes live in Zoom/Chrome; never record silently.\[26\] |
| 5 | Live transcript | Real-time bubbles | **Include** | Required by user. |
| 6 | Me/Them labels | Mic vs system channel | **Include** | Free and 100% accurate for "Me". |
| 7 | Named speaker tags (Zoom, Meet) | Accessibility / Chrome extension | **Include** | Required ("which speaker said which thing"). |
| 8 | Acoustic diarization of "Them" | Mobile in-person only | **Include (post-meeting)** | Fallback when names aren't available (e.g. a Meet tab in the background). |
| 9 | Rename/merge speakers | Correct in notes or via chat | **Include** | Cheap; essential for accuracy. |
| 10 | Notepad + Enhance | Core | **Include** | The product's soul. |
| 11 | Templates (built-in + custom + Auto) | 29 built-ins, custom | **Include (~6 built-ins + custom; Auto via LLM)** | Core. |
| 12 | Recipes (/ prompts) | Static saved prompts | **Include** | Low cost once chat exists. |
| 13 | Chat over one meeting | Yes, with citations | **Include** | High value. |
| 14 | Chat across meetings/folders | Agentic, citations | **Include (basic: FTS retrieval + LLM)** | High value; a simple version is enough. |
| 15 | Full transcript viewer | Yes (not editable) | **Include + editable** | Required; editing is an improvement. |
| 16 | Search | Notes, people, companies | **Include (SQLite FTS5)** | Core. |
| 17 | Folders | Spaces > folders | **Include (flat folders + tags)** | Trivial; no spaces. |
| 18 | Export/copy | Copy, CSV, share | **Include (Markdown/plain text/clipboard, .md file)** | Replaces sharing. |
| 19 | Audio retention | Never stored | **Include as opt-in, local only** | Allows re-transcription and playback; user controls retention. |
| 20 | Sharing links / email attendees | Yes | **Defer/never** | Single user. |
| 21 | Team spaces, workspace recipes | Yes | **Never** | Non-goal. |
| 22 | Slack/Notion/CRM/Zapier | Business tier | **Never (MVP)** | Copy-paste Markdown covers it. |
| 23 | MCP server / API | Yes | **Defer (v2)** | Lets Claude Desktop/Code query LapCat; nice, not core. |
| 24 | Briefs (pre-meeting prep) | Since May 2026\[17\] | **Defer (v2)** | Nice-to-have. |
| 25 | Heads Up consent notices | Calendar add-on / Enterprise | **Defer; include consent reminder + canned chat message** | Legal hygiene without integrations. |
| 26 | Mobile / in-person | iOS/Android | **Never (MVP)** | Non-goal; in-person on the Mac still works via "Me" mic channel. |
| 27 | Multi-language | Yes | **Partial** | Parakeet v3 covers 25 European languages;\[27\] Whisper is multilingual.\[28\] English first. |
| 28 | Starring | Yes | **Include** | Trivial. |
| 29 | File import | Not supported | **Defer** | Easy add later (same pipeline). |

---

## 5. User Stories

1. **Prompted capture.** When Zoom or a Meet tab starts using my mic, LapCat shows a notification ("Record 'Weekly sync with Priya'?") pre-filled from my calendar. One click starts recording.
2. **Manual capture.** I can hit a global hotkey or the menu-bar icon to start a "New Note" for an unscheduled call.
3. **Stay present.** During the call I type rough bullets in a clean notepad while a collapsible side panel streams the live transcript.
4. **Who said what.** In the transcript I see "Me" for my lines and real names ("Priya Shah") for others on Zoom/Meet. When names aren't available I see "Speaker 1/2" and can rename them once for the whole meeting.
5. **Enhance.** When I click End (or the call's mic goes idle and I confirm), LapCat produces enhanced notes in my chosen template. My own bullets stay visually distinct from AI-added text, and AI claims link to transcript timestamps.
6. **Template.** I can switch templates (1:1, Stand-up, Customer call, Interview, Project review, General) and re-enhance; I can write my own template in Markdown.
7. **Ask.** I can ask "What did Priya commit to?" about this meeting, or "/Follow-up email", and get an answer with citations to transcript lines.
8. **Recall.** I can search "pricing" across all meetings and jump to the exact transcript line, or ask "What did customers say about onboarding in the last month?"
9. **Full transcript.** I can open the complete transcript with timestamps and speakers, fix misheard words, and copy or export it.
10. **Export.** I can copy enhanced notes as Markdown (for Slack/Notion/email) or save the meeting as a .md file.
11. **Privacy control.** I can choose whether raw audio is kept (and for how long), and which LLM provider (Claude CLI, API key, local) is used, per meeting or globally.
12. **Offline.** On a plane, with no network, recording, transcription, diarization and local-model enhancement all still work.

---

## 6. Functional Requirements

### FR-1 Meeting detection & recording
- **FR-1.1** Watch input devices for "running somewhere" via Core Audio (`kAudioDevicePropertyDeviceIsRunningSomewhere`). On macOS 14.2+, also use Core Audio process objects to identify *which* process is capturing (zoom.us, Google Chrome, Safari, Arc, etc.). Install listeners on every input device, not just the default: Chrome remembers a per-site mic choice, so a Meet call on non-default AirPods would otherwise be missed. Debounce listener bursts.\[29\]
- **FR-1.2** Known Bluetooth gap: Bluetooth mics can report inactive even when in use. Add secondary signals: a calendar event in progress (EventKit) and, optionally, an active Chrome/Safari tab URL matching `meet.google.com` (AppleScript/Automation permission).\[30\]\[31\]
- **FR-1.3** Detection only **prompts**; it never auto-records. A prompted session may auto-stop after the meeting app releases the mic for more than 60 s (with a notification); manual sessions never auto-stop.\[26\]
- **FR-1.4** Link the session to the overlapping calendar event (title, attendees, organizer, conferencing URL) when one exists.
- **FR-1.5** Recording indicator always visible in the menu bar with elapsed time; Pause/Resume/End controls; global hotkeys.
- **FR-1.6** Crash safety: audio and transcript segments are flushed to disk incrementally (every ≤5 s), so a crash loses at most seconds.

### FR-2 Audio capture
- **FR-2.1** Two independent streams: **mic** (AVAudioEngine input node, selected device) and **system/app audio** (Core Audio process tap via `AudioHardwareCreateProcessTap` + `CATapDescription`, read through a private aggregate device).\[32\]\[33\]
- **FR-2.2** Tap scope: default is "meeting app only" (tap the detected process: Zoom, or the browser running Meet); option for "all system audio except LapCat".
- **FR-2.3** Echo handling: if I'm on speakers, remote voices leak into the mic. Mitigations: (a) enable Apple voice processing (AEC) on the mic input; (b) post-hoc de-duplication: drop mic segments whose text closely matches a simultaneous "Them" segment; (c) a UI hint recommending headphones.
- **FR-2.4** Fallback capture path for when a tap fails: ScreenCaptureKit audio-only capture.\[32\]
- **FR-2.5** Resample both streams to 16 kHz mono Float32 for STT; optionally persist as compressed AAC/Opus per channel (FR-9).
- **FR-2.6** Handle device changes mid-call (AirPods connect/disconnect, sleep/wake) by rebuilding the tap and aggregate device. Rebuild both the tap and the aggregate device, because restarting only one is unreliable.\[34\]

### FR-3 Live transcript
- **FR-3.1** Streaming transcription per channel with VAD-gated chunks; partial ("volatile") text replaced by finalized text.
- **FR-3.2** Target latency: finalized text appears ≤3 s after speech ends on Apple Silicon and ≤8 s on Intel (see NFRs).
- **FR-3.3** Bubble UI mirroring Granola: "Them" left/grey, "Me" right/accent color, with speaker name headers when known.
- **FR-3.4** Post-meeting **final pass**: re-transcribe the full recording per channel with the highest-quality model available. It replaces the live transcript, keeping my edits and speaker mappings by timestamp alignment.

### FR-4 Speaker attribution
- **FR-4.1 Channel layer:** mic → "Me" (the user's name from settings); system/app → "Them" placeholder.
- **FR-4.2 Platform layer (live names):**
  - **Zoom desktop:** with Accessibility permission, poll the Zoom window's accessibility tree (~4 Hz) for the participant list and the active-speaker indicator; write `(timestamp, displayName)` events.
  - **Google Meet (Chrome/Safari/Arc):** read the active-speaker highlight and participant tiles from the browser's accessibility tree. This works best when the Meet tab is visible. If accessibility data is missing, fall back to FR-4.3.
  - Assign each "Them" segment the display name with the most active-speaker overlap during its time span.
- **FR-4.3 Acoustic layer (post-meeting):** run diarization (segmentation + speaker embeddings + clustering) on the "Them" channel only. Map clusters to names using the platform-layer events. Unmapped clusters become "Speaker N".
- **FR-4.4 Name resolution:** candidate names come from calendar attendees + platform display names. The LLM may *suggest* mappings from conversational cues ("Thanks, Priya"), but suggestions are shown as suggestions until confirmed.
- **FR-4.5 Editing:** rename a speaker (applies meeting-wide), merge two speakers, reassign a single segment.
- **FR-4.6 Persistent voiceprints (stretch):** store speaker embeddings for confirmed names so recurring colleagues are recognized in future meetings. Off by default; delete on demand.

### FR-5 Notepad & AI-enhanced notes
- **FR-5.1** Markdown-backed rich text editor (headings, bullets, checkboxes, bold), available before, during and after the meeting.
- **FR-5.2** **Enhance** combines: my raw notes + full speaker-labeled transcript + calendar metadata (title, attendees) + selected template. Output: structured notes. My original lines are preserved and visually distinguished (Granola-style: my text in black, AI additions in grey).
- **FR-5.3** Every AI-generated bullet carries citation anchors to transcript segment IDs; clicking jumps to the transcript.
- **FR-5.4** Re-enhance with a different template or provider; keep version history of enhanced notes (last 5).
- **FR-5.5** Auto title: generate a meeting title if there's no calendar event.
- **FR-5.6** Long-meeting strategy: if the transcript exceeds the provider's context budget (e.g. local 8K–32K models), use map-reduce. Summarize 10-minute chunks with speaker labels and timestamps, then synthesize the final notes with my bullets. Claude paths (200K+ context) get the full transcript in one shot.

### FR-6 Templates & recipes
- **FR-6.1** Built-in templates: General, 1:1, Stand-up, Customer/Discovery call, Interview, Project review. Each is a Markdown file with section headings plus instructions.
- **FR-6.2** Custom templates are editable files in `~/Library/Application Support/LapCat/templates/`.
- **FR-6.3** "Auto" template: one cheap LLM classification call picks a template from title + attendees + first 5 minutes of transcript.
- **FR-6.4** Recipes: saved static prompts (Granola recipes support no variables,\[10\] but LapCat may add `{{meeting.title}}`-style variables later). Built-ins: Follow-up email, Action items by owner, Decisions log, Open questions, "What did I commit to?". Invoked with "/" in the chat bar.

### FR-7 Chat / Q&A
- **FR-7.1** Per-meeting chat: context = enhanced notes + full transcript; answers include clickable citations.
- **FR-7.2** Cross-meeting chat (basic): retrieve top-K transcript chunks via FTS5 (BM25), optionally scoped by folder/date/person, then answer with citations to (meeting, timestamp). Embedding-based retrieval is a v2 enhancement.
- **FR-7.3** Chat history persisted per meeting and globally.

### FR-8 Full transcript viewer
- **FR-8.1** Dedicated view: timestamps, speaker names, channel, paragraph grouping, jump-to-time, find-in-transcript.
- **FR-8.2** Inline editing of text (edits flagged, original retained).
- **FR-8.3** If audio is retained: click a segment to play from that point.
- **FR-8.4** Copy all / copy selection with speaker labels; export as .md, .txt, .srt/.vtt.

### FR-9 Storage, search & organization
- **FR-9.1** All data local in SQLite (WAL mode) + an audio directory.
- **FR-9.2** FTS5 index over transcript text, raw notes, enhanced notes, titles and attendee names.
- **FR-9.3** Folders (flat), tags, star, and filter by date/person/folder.
- **FR-9.4** Audio retention setting: Never / 7 days / 30 days / Forever (default: 30 days). The transcript is always kept.

### FR-10 Export / copy
- **FR-10.1** One-click "Copy notes as Markdown" and "Copy as plain text (Slack-friendly)".
- **FR-10.2** Export a meeting bundle: `YYYY-MM-DD Title.md` with frontmatter (date, attendees, speakers), enhanced notes, raw notes, transcript.
- **FR-10.3** Optional auto-export folder (e.g. an Obsidian vault) that writes the .md after enhancement.

### FR-11 Settings
- LLM provider and model per task (enhance, chat, classification); STT model; tap scope; detection apps list; my display name; audio retention; consent reminder toggle and canned "I'm taking AI notes" chat message to paste.

---

## 7. Non-Functional Requirements

### Privacy / local-first
- **NFR-P1** Audio never leaves the Mac in the default configuration. On-device STT and diarization is the default on both architectures. (Granola, by contrast, sends audio to a cloud transcription subprocessor.)\[20\]\[35\]
- **NFR-P2** Only text goes to an LLM, and only to the provider I've selected. The UI shows the active provider in the meeting toolbar ("Claude via CLI", "Local").
- **NFR-P3** "Fully offline" mode disables all network calls; verifiable by running with networking off.
- **NFR-P4** Database and audio stored under the user's Library with FileVault as the encryption baseline; optional SQLCipher later.
- **NFR-P5** Accessibility usage limited to reading participant names and active-speaker state from Zoom and the browser; no screen recording beyond the audio tap.

### Performance (targets, to be validated in Phase 0)
| Metric | Apple Silicon (M1+) | Intel (e.g. i7/i9 2019–2020) |
|---|---|---|
| Live transcript finalized latency | ≤3 s | ≤8 s (may use a smaller live model) |
| Final-pass transcription, 60-min meeting | ≤2 min (FluidInference's Hugging Face model card reports "~110× RTF on M4 Pro" for Parakeet TDT v3, i.e. 1 min of audio ≈ 0.5 s; FluidAudio's own docs and README claim ~120× to ~190× on the same chip) | ≤40 min with large-v3-turbo on CPU; ≤15 min with small/base.\[36\] Run in the background |
| Diarization, 60-min "Them" channel | ≤1 min | ≤10 min |
| Enhance (Claude) | ≤60 s | ≤60 s (network-bound) |
| Enhance (local Qwen3-4B Q4) | ≤90 s | 3–10 min (CPU ~single-digit tok/s for 7–8B; 4B somewhat faster)\[37\] |
| CPU during live capture | <25% of one performance core avg | <60% avg; never drops audio |
| Idle CPU with detection on | ≈0% | ≈0% |
| RAM during recording | <1.5 GB | <2.5 GB |

### Latency & reliability
- **NFR-R1** Zero audio loss: capture runs on a real-time thread with a lock-free ring buffer. Transcription falling behind must never block capture; it queues to disk.
- **NFR-R2** Survive sleep/wake, device switches and app crashes (incremental persistence, resume on relaunch).

### macOS version & architecture support
- **NFR-M1** **Minimum macOS 14.2 (Sonoma)**, required for Core Audio process taps and process objects. Below 14.2 the only options are ScreenCaptureKit (with its Screen Recording permission) or a virtual driver like BlackHole,\[25\]\[33\] which isn't worth supporting.
- **NFR-M2** **Universal 2 binary** (arm64 + x86_64). Runtime capability checks select the STT/diarization/LLM backend per architecture.
- **NFR-M3** Optional macOS 26 enhancements: Apple SpeechAnalyzer/SpeechTranscriber (on-device, built for long-form meeting audio)\[38\] as an extra STT option, and the Foundation Models framework for tiny tasks (Apple Silicon + Apple Intelligence only).
- **NFR-M4** Intel is end-of-line: macOS 26 Tahoe is the last macOS for Intel Macs, and macOS 27 (released September 14, 2026) is Apple-Silicon-only.\[39\] Intel support is a hard MVP requirement but should get no investment beyond "works correctly".

### Permissions & entitlements
| Permission | Why | Notes |
|---|---|---|
| Microphone (`NSMicrophoneUsageDescription`) | "Me" channel | Standard TCC prompt. |
| System Audio Recording (`NSAudioCaptureUsageDescription`) | Core Audio process tap | On 14.2+ the tap needs only System Audio Recording, not full Screen Recording. Users see it under Privacy & Security → "Screen & System Audio Recording".\[32\]\[40\] |
| Accessibility | Zoom/Meet speaker names | Manual grant in System Settings; app must be stably signed so the grant persists. |
| Calendars (EventKit full access) | Meeting titles/attendees | Optional. |
| Automation (Apple Events to Chrome/Safari) | Meet tab detection | Optional. |
| Notifications | Detection prompts | Optional. |

- **NFR-E1** Run **unsandboxed**, signed with a personal Apple Development certificate. This avoids sandbox friction with Accessibility, Apple Events, spawning `claude`, and llama.cpp. Hardened Runtime is optional for local use. A stable signing identity keeps TCC grants from resetting on every rebuild.

---

## 8. AI / Model Strategy

### 8.1 Speech-to-text (STT)

| Option | Apple Silicon | Intel | Quality | Notes |
|---|---|---|---|---|
| **Parakeet TDT 0.6B v2/v3 via FluidAudio (Core ML, ANE)** | **Primary** | Not supported in practice | Excellent English (v2); v3 adds 25 European languages | FluidInference's model card reports "~110× RTF on M4 Pro" (1 min audio ≈ 0.5 s); FluidAudio's newer docs say ~120× and its README ~190×, so even the vendor's numbers disagree. ~800 MB peak memory (v2); macOS 14+. One open-source app (OpenWhispr) logged Intel FluidAudio as a known "won't fix" limitation.\[41\] Spokenly claims Parakeet v3 runs on Intel via another runtime;\[42\] unverified. |
| **whisper.cpp (GGML; Metal on AS, AVX on Intel)** | Fallback | **Primary** | large-v3-turbo ≈ large-v3 accuracy (809M params, 1.6 GB)\[28\]\[36\]\[43\]\[44\] | Third-party RTF tables for Intel i7 CPU: turbo ~0.6× real-time, i.e. a 60-min meeting in ~36 min; large-v3 ~3× real-time (too slow).\[36\] Quantized q5/q8 turbo and `small.en` are the Intel live options.\[45\] |
| **Apple SpeechAnalyzer / SpeechTranscriber** | Optional (macOS 26+) | Optional only on the 4 Intel Macs that run Tahoe; Intel runtime untested | Good; designed for long-form/distant audio | Free, on-device, system-managed models. No custom vocabulary on the long-form model.\[46\]\[47\] |
| **WhisperKit (Core ML)** | Alternative | Weak | Good | Overlaps with Parakeet/whisper.cpp; skip for MVP. |
| **Moonshine / tiny Whisper** | — | Live-preview option | Lower | Only if Intel live latency is unacceptable. |
| **Cloud STT (e.g. Deepgram, AssemblyAI, OpenAI)** | Optional fallback | Optional fallback | Best-in-class + cloud diarization | Breaks local-first; offer only as an explicit opt-in "fast final pass" on Intel. |

**Recommendation.** Use a `TranscriptionEngine` protocol with two implementations: `ParakeetEngine` (FluidAudio, arm64) and `WhisperCppEngine` (both architectures). Apple Silicon: Parakeet for both live and final passes. Intel: whisper.cpp `small.en` (or quantized turbo, if Phase 0 shows it keeps up) for live, and large-v3-turbo q5 for the background final pass. SpeechAnalyzer is a Phase-3 option.

### 8.2 Speaker diarization

| Approach | Role in LapCat | Notes |
|---|---|---|
| **Channel separation (mic vs. tap)** | Always on | Exactly Granola's Me/Them model. Accurate for "Me" except for echo leakage (FR-2.3). |
| **Zoom/Meet active-speaker via Accessibility** | Primary naming for remote speakers | Same mechanism Granola uses; brittle to UI changes (risk R3). Can't separate a shared room device or overlapping speech.\[6\] |
| **FluidAudio diarization (pyannote Community-1, Sortformer; Core ML)** | Apple Silicon acoustic layer | The MacParakeet blog, a third-party source rather than FluidInference's own benchmark, reports "Pyannote Community-1 \| 122x realtime, 15% DER"; online and offline modes. |
| **sherpa-onnx (pyannote segmentation + speaker-embedding ONNX models)** | Intel acoustic layer | Cross-platform C/C++ with Swift-callable C API; OpenWhispr uses it as its Intel fallback.\[41\] |
| **pyannote (Python) / NeMo** | Not used | Python/CUDA dependency is wrong for a native Mac app. |
| **Zoom/Meet APIs / bots** | Not used | Requires bots or tenant apps; contradicts the bot-free design. |

### 8.3 LLM for enhancement, chat and recipes

**(a) Using the Anthropic subscription: what's actually allowed (as of October 1, 2026).**
- Anthropic's current Claude Code legal page says OAuth authentication "is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications." It says developers building products, "including those using the Agent SDK, should use API key authentication." It also says "developers may not collect, store, or intermediate Claude.ai credentials or session tokens."\[48\]
- The same page explicitly does **not** prevent "an end user from signing in to the unmodified Claude Code binary with their own Claude subscription." Advertised Pro/Max limits "assume ordinary, individual usage of Claude Code and the Agent SDK."\[48\]
- History: in February 2026 the docs briefly said using subscription OAuth tokens in any other product, "including the Agent SDK," was not permitted.\[49\] Anthropic enforced blocks against third-party harnesses in January and April 2026.\[50\] A planned June 15, 2026 move to a separate monthly Agent SDK credit ($20 Pro / $100 Max 5x / $200 Max 20x) was **paused** on the day it was due.\[51\]\[52\] Anthropic's help center now says "Claude Agent SDK, `claude -p`, and third-party app usage still draw from your subscription's usage limits" and promises notice before any future change.\[53\]
- **Interpretation:** the defensible path for a single-user personal tool is to **invoke the official, unmodified `claude` CLI that I've signed into myself**, in headless mode (`claude -p --output-format json`, prompt on stdin). LapCat never reads, stores or proxies the OAuth token. Avoid extracting `CLAUDE_CODE_OAUTH_TOKEN` into custom HTTP clients. The policy has changed several times this year, so treat this path as "allowed today, could change" and keep a fallback ready.

**(b) API-key fallback.** Anthropic API with a Console key in the macOS Keychain. Default model **Claude Haiku 4.5** ($1 input / $5 output per million tokens, 200K context, 64K max output).\[54\] A 60-minute meeting is roughly 10–15K transcript tokens, so an enhance costs about 2–3 cents. Offer **Sonnet 5.5** ($2/$10, 1M context)\[55\] for cross-meeting chat.

**(c) Small local models.**

| Option | Apple Silicon | Intel | Notes |
|---|---|---|---|
| **llama.cpp (embedded via Swift package or `llama-server` sidecar), GGUF** | Metal GPU | CPU (AVX2) | **The only runtime that covers both architectures well.** Recommended. |
| Ollama | Yes (MLX backend in recent versions)\[56\] | Yes (CPU)\[37\] | Easy, but an external daemon; fine as an alternative endpoint via its OpenAI-compatible API. |
| MLX / mlx-swift | Fastest on Apple Silicon\[56\]\[57\] | **No (Apple Silicon only)**\[57\] | Optional AS speed-up later; not needed for MVP. |
| Apple Foundation Models (~3B on-device) | macOS 26 + Apple Intelligence (M1+) only | **No** | Fixed **4,096-token** context covering input *and* output.\[58\]\[59\] Fine for titles/classification; too small for enhancing a full transcript.\[60\] |

| Model (Q4_K_M) | Size | Fit for meeting notes | Speed |
|---|---|---|---|
| **Qwen3-4B / Qwen3.5-4B Instruct** | ~2.5 GB\[61\] | **Recommended default local**: strong instruction following, long context (use 32K) | ~43 tok/s on M3 Pro (qwen3:4b, Ollama);\[62\] expect low single-digit to ~10 tok/s on Intel CPU\[37\] |
| Gemma 4 E2B / E4B | ~1.5 / ~4.5 GB | Good summarizer; E2B for 8 GB Macs | 30–45 / 25–40 tok/s on base M-series\[61\] |
| Llama 3.2 3B | ~2 GB | Adequate | 25–35 tok/s on 8 GB Macs\[61\] |
| Phi-4 Mini 3.8B | ~2.3 GB | Good reasoning; weaker prose | 25–40 tok/s\[61\] |
| Qwen3-8B / Llama 3.1 8B | ~4.5–5 GB | Noticeably better notes | Apple Silicon only in practice; 3–8 tok/s on Intel i9\[37\] |
| SmolLM / Qwen 0.6–1.7B | <1.5 GB | Classification/titles only | Very fast\[56\] |

**Context-window strategy for long meetings.** Local models run at a 16K–32K context setting to keep RAM and prompt-processing time sane. Prompt-processing on Intel CPU is the real bottleneck, so use FR-5.6 map-reduce for anything over ~12K tokens. Claude paths send the full transcript.

**(d) "Jev".** Research turned up **Jev**, a model from TypeSafe AI (out of stealth September 15, 2026). It's a non-generative "System One" model: you send state plus typed questions (yes/no, choice, score) and it returns calibrated probabilities in ~70–500 ms, at $0.042 per million input tokens. It "cannot write a reply… summarize a document," is text-only, and is **hosted only**: "TypeSafe hasn't published Jev's weights."\[63\] Community imitations (LLM2Jev, jev-local, LocalJev) mimic its API on top of local LLMs.\[64\]\[65\]\[66\] **Conclusion:** Jev isn't a teeny tiny local summarizer and can't do note enhancement. If you meant something else by "jev", that still needs confirming. It *could* later cover LapCat's small decisions: Auto-template selection, "is this a meeting?" detection, "is this line an action item?", or choosing which attendee a speaker cluster most likely is. Mark it as a v2 experiment behind the same `DecisionProvider` interface the local small model uses.

### 8.4 Final recommendation
1. **Default provider: Claude via the signed-in `claude` CLI** (Sonnet-class model for Enhance; Haiku-class for Auto-template/titles if the CLI allows model selection). This uses the subscription, gives the best note quality, and handles 200K+ contexts.
2. **Fallback 1: Anthropic API key** (Haiku 4.5). Use when the CLI is missing, rate-limited, or policy changes.
3. **Fallback 2 / offline: Qwen3-4B Q4 via embedded llama.cpp** on both architectures, with map-reduce.
4. **Tiny tasks:** local Qwen 0.6–1.7B (both architectures) or Apple Foundation Models on AS/macOS 26.
5. All providers sit behind one `LLMProvider` protocol (`complete(system:, messages:, maxTokens:, json:)`, plus streaming). Automatic failover order is configurable.

---

## 9. Technical Architecture

### 9.1 Stack decision
**Native Swift 6 + SwiftUI (AppKit where needed), Universal binary.** Tauri/Electron would put a JS/Rust layer between you and the parts that matter most: Core Audio taps, AVAudioEngine, Accessibility (AXUIElement), EventKit, Core ML/ANE (FluidAudio is a Swift SDK),\[67\] and Keychain. For a solo Mac-only developer, native is less code and less glue.

| Layer | Choice |
|---|---|
| UI | SwiftUI (menu-bar extra + main window), AppKit `NSTextView`/TextKit 2 for the notepad editor |
| Audio | AVAudioEngine (mic, voice processing) + Core Audio process tap + private aggregate device; ScreenCaptureKit fallback |
| STT | FluidAudio Parakeet (arm64), whisper.cpp via SPM/XCFramework (both architectures) |
| Diarization | FluidAudio (arm64), sherpa-onnx C API (x86_64) |
| Speaker names | AXUIElement observers/polling for Zoom + browsers |
| Calendar | EventKit |
| LLM | `Process` → `claude -p` (JSON output); URLSession → Anthropic Messages API; llama.cpp (embedded) |
| Storage | SQLite via GRDB.swift (WAL, FTS5, migrations) |
| Secrets | Keychain (API key only) |
| Concurrency | Swift actors per pipeline stage; real-time audio thread → lock-free ring buffer → async consumers |

### 9.2 Pipeline

```
[Detector] --prompt--> [SessionController]
                         |
        +----------------+-----------------+
        |                                  |
 [MicCapture: AVAudioEngine+AEC]   [AppTap: CATapDescription(process=Zoom/Chrome)]
        |                                  |
   ring buffer → 16kHz mono          ring buffer → 16kHz mono
        |                                  |
   [Disk writer: mic.m4a]            [Disk writer: them.m4a]
        |                                  |
   [VAD → Live STT (Me)]             [VAD → Live STT (Them)]
        \                                  /
         +---> [TranscriptStore (SQLite)] <---- [SpeakerEventStream (AX: Zoom/Meet active speaker)]
                         |
                 (on End)
                         v
   [Final pass STT per channel] → [Diarize Them] → [Align + name mapping] → [Echo de-dup]
                         |
                         v
   [Enhancer: notes + transcript + template → LLMProvider] → [EnhancedNote + citations]
                         |
                 [FTS index update] → [Optional auto-export .md]
```

### 9.3 Real-time vs. post-meeting processing
- **During the meeting:** capture + live STT only, plus the AX speaker-event stream. Keep it light so audio never drops and Intel stays cool.
- **After End:** the final-pass STT, diarization, alignment, de-duplication and enhancement run as a resumable background job with a progress UI. Enhanced notes from the live transcript can appear immediately (a "quick enhance"), then refresh automatically when the final pass completes.

---

## 10. Data Model (SQLite)

| Table | Key columns |
|---|---|
| `meeting` | id (UUID), title, started_at, ended_at, status (recording/processing/ready/error), source_app (zoom/meet/other), calendar_event_id, folder_id, starred, template_id, llm_provider_used, audio_retained_until |
| `calendar_snapshot` | meeting_id, event_title, organizer, attendees_json, conference_url, scheduled_start/end |
| `participant` | id, meeting_id, display_name, email (nullable), source (calendar/zoom_ax/meet_ax/manual/llm_suggested), is_me, voiceprint_id (nullable) |
| `speaker_event` | meeting_id, t_start_ms, t_end_ms, display_name, source (zoom_ax/meet_ax) |
| `segment` | id, meeting_id, channel (mic/system), t_start_ms, t_end_ms, text, text_original (if edited), participant_id (nullable), cluster_label (nullable), confidence, pass (live/final), is_echo_duplicate |
| `raw_note` | meeting_id, markdown, updated_at |
| `enhanced_note` | id, meeting_id, version, template_id, provider, model, markdown, citations_json (bullet → segment ids), created_at |
| `template` | id, name, body_markdown, is_builtin |
| `recipe` | id, name, slash_command, prompt, is_builtin |
| `chat_thread` / `chat_message` | thread id, scope (meeting/folder/global), role, content, citations_json |
| `folder` / `tag` / `meeting_tag` | standard |
| `voiceprint` | id, participant_name, embedding blob, created_at (opt-in) |
| `audio_file` | meeting_id, channel, path, codec, duration_ms |
| `fts_content` (FTS5 virtual) | meeting_id, kind (segment/raw/enhanced/title/person), ref_id, text |

Files: `~/Library/Application Support/LapCat/{lapcat.sqlite, audio/<meeting-id>/{mic,them}.m4a, models/, templates/, exports/}`.

---

## 11. Risks & Open Questions

| # | Risk / question | Likelihood / impact | Mitigation |
|---|---|---|---|
| R1 | **Anthropic subscription policy changes again** (it changed in January, February, April and June 2026)\[50\]\[51\] | Medium / Medium | Use only the unmodified CLI; never touch tokens; API-key and local fallbacks; provider shown per meeting. |
| R2 | **Recording consent / legality.** According to the Reporters Committee for Freedom of the Press, about 11 US states mainly require all-party consent (California, Delaware, Florida, Illinois, Maryland, Massachusetts, Michigan, Montana, New Hampshire, Pennsylvania and Washington), and many countries have their own rules. Granola puts disclosure on the user | Medium / High | Consent reminder at start; one-click "paste disclosure into meeting chat"; per-meeting "consent confirmed" flag; audio retention defaults; never auto-record. Not legal advice. Check the rules in my jurisdiction and employer policy, including company rules on AI notetakers and on sending meeting text to Anthropic. |
| R3 | **Zoom/Meet Accessibility trees change** and break speaker names | High / Medium | Isolate per-app adapters; acoustic diarization fallback; "Speaker N" + quick rename. |
| R4 | **Meet active speaker unreadable when tab hidden** or in a non-Chrome browser | Medium / Medium | Fallback to diarization; document "keep the Meet tab visible"; consider a tiny Chrome extension in v2 (Granola supports both).\[6\] |
| R5 | **Echo** on laptop speakers duplicates "Them" speech into "Me" | High (without headphones) / Medium | AEC + text de-duplication + headphone hint. |
| R6 | **Intel performance** too slow for live + final pass | Medium / Medium | Smaller live model; background final pass; optional opt-in cloud STT; accept that Intel is end-of-line. |
| R7 | **Process tap quirks**: all-zero buffers, needing to rebuild after device changes, two taps interfering\[34\] | Medium / High | Health monitor (detect silence while output is active), automatic tap + aggregate rebuild, ScreenCaptureKit fallback, mic-only degrade with warning. |
| R8 | **Bluetooth mic** "in use" detection gaps | Medium / Low | Calendar + browser-tab signals; manual hotkey.\[30\]\[31\] |
| R9 | TCC permission grants reset on rebuild (unstable signing) | High during dev / Low | Stable signing identity; onboarding checklist screen that verifies each permission. |
| R10 | Local LLM hallucination in notes | Medium / Medium | Citations required per bullet; "unsupported claim" flag if no citation; Claude default. |
| Q1 | Which Intel Mac and macOS version will actually be used? (Determines whether SpeechAnalyzer is an option.) | — | Confirm in Phase 0. |
| Q2 | What did "jev" refer to? TypeSafe's Jev doesn't fit the "teeny tiny local model" description. | — | Confirm with user; default plan works without it. |
| Q3 | Keep audio by default (enables re-transcription) or mirror Granola's "never store"? | — | Proposed default: keep 30 days, local only. |
| Q4 | Does the installed `claude` CLI version allow choosing the model in headless mode and returning clean JSON reliably? | — | Spike in Phase 0. |
| Q5 | Is Microsoft Teams needed soon? (The architecture supports another AX adapter.) | — | Out of MVP. |

---

## 12. Success Metrics

| Metric | Target (after 4 weeks of daily use) |
|---|---|
| Capture reliability | ≥99% of meetings I intended to record have complete audio on both channels |
| Missed meetings | 0 meetings lost due to app failure; detection prompt shown for ≥95% of Zoom/Meet calls |
| "Me" attribution accuracy | ≥98% of my speech labeled Me (with headphones); ≥90% on speakers |
| Remote speaker naming | ≥85% of "Them" speech time correctly named on Zoom; ≥70% on Meet |
| Transcript quality | Subjective "readable without audio" for ≥90% of meetings; spot-check WER ≤10% on clean English |
| Time to notes | Enhanced notes ≤2 min after End (Apple Silicon, Claude); ≤10 min (Intel, local) |
| Note usefulness | I use LapCat notes instead of my own write-up in ≥80% of meetings; edits per enhanced note trend down |
| Recall | Find a remembered quote via search/chat in <30 s |
| Privacy | 0 audio bytes leave the machine (verified with a network monitor) in default mode |
| Cost | ≤$5/month marginal API spend (if API fallback used) |

---

## 13. Milestones / Phased Roadmap

| Phase | Duration (solo, part-time) | Scope | Exit criteria |
|---|---|---|---|
| **0. Spikes** | 1 week | Process tap of Zoom + Chrome on both Macs; AEC test; whisper.cpp vs Parakeet RTF on Intel and AS; `claude -p` JSON round-trip; AX read of Zoom active speaker | Benchmarks recorded; go/no-go on Intel live model |
| **1. Capture + transcript** | 2 weeks | Dual-channel capture, disk persistence, live STT, bubble transcript, Me/Them, SQLite, manual start/stop | Record a 60-min call on both Macs, no drops, readable transcript |
| **2. Notes + AI** | 2 weeks | Notepad, Enhance with citations, templates, LLMProvider (CLI, API, llama.cpp), map-reduce, final pass | Enhanced notes I'd actually send |
| **3. Speakers + detection** | 2 weeks | Zoom/Meet AX adapters, diarization (FluidAudio/sherpa-onnx), name mapping, rename/merge, EventKit, mic-in-use detection prompts | Named speakers on Zoom; prompt shown when a call starts |
| **4. Recall + polish** | 1–2 weeks | FTS5 search, per-meeting & cross-meeting chat, recipes, folders/tags/star, export, retention, onboarding/permissions checklist, transcript editing & playback | All MVP FRs met; daily-driver ready |
| **v2 (later)** | — | Local MCP server (let Claude Desktop/Code query LapCat), embeddings for chat, voiceprints, Briefs, Chrome extension for Meet, Teams adapter, file import, SpeechAnalyzer engine, Jev/decision-model experiments | — |

---

## 14. Recommended Build Order

1. **Permissions + signing scaffold:** menu-bar app, stable dev signing, onboarding checklist for Microphone, System Audio Recording, Accessibility and Calendars.
2. **Audio capture core:** mic via AVAudioEngine and a Core Audio process tap targeting Zoom/Chrome. Write both channels to disk, with a health monitor and rebuild-on-device-change. *Highest technical risk, so it goes first.*
3. **SQLite schema (GRDB) + session lifecycle** (start/pause/end, crash recovery).
4. **TranscriptionEngine protocol** → whisper.cpp first, since it covers both architectures and proves Intel early. Then the Parakeet/FluidAudio engine for arm64.
5. **Live transcript UI** (bubbles, Me/Them) and the **full transcript viewer**.
6. **LLMProvider protocol** → `claude -p` CLI provider → API-key provider → llama.cpp provider.
7. **Notepad + Enhance** with templates, citations and map-reduce; post-meeting final-pass job.
8. **Speaker attribution:** Zoom AX adapter → Meet AX adapter → diarization (FluidAudio / sherpa-onnx) → alignment + rename/merge → echo de-dup.
9. **Calendar (EventKit) + meeting detection prompts** (Core Audio process objects + calendar + browser tab).
10. **Search (FTS5) → chat (per-meeting, then cross-meeting) → recipes.**
11. **Organization + export + retention settings** (folders, tags, star, Markdown export, auto-export folder).
12. **Hardening:** 2-hour meeting soak tests on both Macs, sleep/wake, AirPods switching, offline mode verification.

---

## 15. Caveats

- Several Granola details come from third-party reviews and can conflict. For the free tier, for example, some reviewers claim a 25-note cap, but Granola's own help center describes a 30-day in-app window with older notes kept, not deleted. Granola's own docs and blog are treated as authoritative for behavior. Pricing and features change often.
- Performance figures (Parakeet RTF, whisper.cpp on Intel, local-LLM tokens/sec) come from vendor and community benchmarks on different hardware. They're planning estimates; Phase 0 must measure on your Macs.
- Anthropic's subscription-usage policy has changed several times in 2026 and the current wording doesn't explicitly address a personal self-built app. The CLI-shell-out approach is a reasoned interpretation, not an official ruling.
- Recording-consent law varies by jurisdiction; this PRD's consent features are hygiene, not legal advice.

## Sources

1. [Granola Review 2026: Is the AI Meeting Notepad Worth It?](https://skillscouter.com/granola-review/)
2. [How transcription works - Granola Docs & Help Center](https://docs.granola.ai/help-center/taking-notes/transcription)
3. [Granola AI Review (2026): My Daily-Use Verdict](https://zackproser.com/blog/granola-ai-review)
4. [Security, Privacy & Data FAQs - Granola Docs & Help Center](https://docs.granola.ai/help-center/consent-security-privacy/security-privacy-data-faqs)
5. [Common feature requests - Granola Docs & Help Center](https://docs.granola.ai/help-center/feature-requests)
6. <https://docs.granola.ai/help-center/taking-notes/speaker-attribution>
7. [How transcription works - Granola Docs & Help Center](https://docs-granola-ai.translate.goog/help-center/taking-notes/transcription?_x_tr_sl=en&_x_tr_tl=pt&_x_tr_hl=pt&_x_tr_pto=tc)
8. [Granola AI Review 2026: Workflow, Pricing & Real Limits](https://www.itsconvo.com/blog/granola-ai-review)
9. [What is Granola? The AI note taker everyone's talking about](https://zapier.com/blog/granola-ai/)
10. [Recipes - Granola Docs & Help Center](https://help.granola.ai/article/recipes)
11. [Meeting recall: How to find what someone said months ago](https://www.granola.ai/blog/meeting-recall-search-transcripts)
12. [Granola - AI Meeting Notes - App Store - Apple](https://apps.apple.com/us/app/granola-ai-meeting-notes/id6739429409)
13. [Granola Release Notes - September 2026 Latest Updates - Releasebot](https://releasebot.io/updates/granola)
14. [Granola - AI Meeting Notes - Apps on Google Play](https://play.google.com/store/apps/details?id=ai.granola&hl=en_US)
15. [Granola AI Review: My Honest Thoughts After 20+ Meetings (2026)](https://tldv.io/blog/granola-review/)
16. [GitHub - moona3k/granola-export: Recover your own Granola.ai data — meeting notes, transcripts, AI summaries — via the REST API. MIT licensed, personal use only.](https://github.com/moona3k/granola-export)
17. [Granola AI Review (2026): Pricing, Limits, Why We Left - Kai](https://hirekai.ai/blog/granola-review)
18. [Granola Encrypted Your Meeting Notes. Here's What Changed and How to Get Them Out](https://www.getvoibe.com/resources/granola-encrypted-notes/)
19. [When to Use AI Notetaking: A Guide for Your Team - Granola Docs & Help Center](https://docs.granola.ai/help-center/consent-security-privacy/getting-consent)
20. [Is Granola AI Safe? Granola Privacy Audit (2026) - Routines](https://getroutines.ai/transparency/granola-ai)
21. [Granola Review 2026](https://thebusinessdive.com/granola-review)
22. [workspace.google.com](https://workspace.google.com/marketplace/app/granola_for_google_calendar_zoom/906368641173?hl=sl)
23. [Setup guide - Granola Docs & Help Center](https://docs.granola.ai/help-center/getting-started/setting-up-granola-for-the-first-time)
24. [AudioTee: capture system audio output on macOS — Strongly Typed](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos)
25. [Core Audio tap: capturing macOS system audio without a virtual device](https://askcanary.com/glossary/coreaudio-tap/)
26. [Offer to record when a call takes the microphone · Issue #65 · humanitas-labs/quill](https://github.com/humanitas-labs/quill/issues/65)
27. [FluidInference/parakeet-tdt-0.6b-v3-coreml · Hugging Face](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
28. [Whisper Large V3 Turbo vs V3: 5× Faster on Mac (Benchmark)](https://whispernotes.app/blog/introducing-whisper-large-v3-turbo)
29. [Macnotetaker](https://macnotetaker.com/blog/which-app-is-using-mic-coreaudio-process-objects)
30. [GitHub - joeyzhao123/lookaway-lite: macOS menu bar 20-20-20 break reminder that holds breaks while you're in a meeting (mic/camera/Meet tab/calendar detection) · GitHub](https://github.com/joeyzhao123/lookaway-lite)
31. [Detect when (internal or external) microphone is being used](https://developer.apple.com/forums/thread/741026)
32. [feat(audio): capture system audio with a Core Audio process tap by deepratna-awale · Pull Request #30 · deepratna-awale/open-wallpaper-engine-mac](https://github.com/deepratna-awale/open-wallpaper-engine-mac/pull/30)
33. [Capturing System Audio on macOS in 2026: What an iOS Dev Needs to Know - DGR Labs](https://dgrlabs.co/blog/2026-04-25-capturing-system-audio-on-macos-in-2026.html)
34. [Core Audio](https://developer.apple.com/forums/tags/core-audio)
35. [Is Granola private? Training, recording and lawsuit](https://aileakage.com/vendors/granola/)
36. [Whisper Model Sizes: Complete Guide](https://openwhispr.com/blog/whisper-model-sizes-explained)
37. [How to Run Local LLMs on an Intel Mac (2026) — What's Possible & Realistic Speeds](https://llmcheck.net/guides/run-local-llm-intel-mac/)
38. [A Quick Look at Apple's SpeechAnalyzer API](https://blog.addpipe.com/apple-speechanalyzer-api/)
39. [macOS 27 & Tahoe 26 Compatibility: Supported Macs](https://mac.install.guide/macos/compatibility)
40. [Transcription issues - Granola Docs & Help Center](https://docs.granola.ai/help-center/troubleshooting/transcription-issues)
41. [docs: record the Intel Mac FluidAudio limitation as won't fix by futuregerald · Pull Request #71 · futuregerald/openwhispr](https://github.com/futuregerald/openwhispr/pull/71)
42. [Parakeet vs Whisper: Best Local Speech Model 2026](https://spokenly.app/blog/parakeet-vs-whisper)
43. [Whisper Model Sizes: Tiny to Turbo Compared — MetaWhisp](https://metawhisp.com/blog/whisper-model-sizes-mac/)
44. [Whisper Large-v3 vs Turbo (2026): Speed, WER & Cost Compared](https://vexascribe.com/whisper-large-v3-vs-turbo)
45. [Whisper.cpp Benchmark Report: Complete Performance Analysis on Legacy Hardware (Intel Core i5-460M) · ggml-org/whisper.cpp · Discussion #3752](https://github.com/ggml-org/whisper.cpp/discussions/3752)
46. [Apple's New Speech Framework: SpeechAnalyzer vs SFSpeechRecognizer](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)
47. [Apple SpeechAnalyzer Review (2026): Honest Verdict on the On-Device Speech API That Benchmarks Against Whisper · Kompozy](https://kompozy.io/reviews/apple-speechanalyzer)
48. <https://code.claude.com/docs/en/legal-and-compliance>
49. [Anthropic Banned OpenClaw: The OAuth Lockdown That Fractured the Claude Developer Community — Natural 20](https://natural20.com/coverage/anthropic-banned-openclaw-oauth-claude-code-third-party)
50. [Anthropic Banned Third-Party Claude Auth: Full Guide 2026](https://kersai.com/anthropic-killed-third-party-claude-access-heres-every-workaround-that-still-works/)
51. [Anthropic pauses Claude Agent SDK subscription change on day it was due to take effect - The New Stack](https://thenewstack.io/anthropic-pauses-claude-agent-sdk-subscription-change/)
52. [What are Claude usage credits? The three things people mean by it](https://fazm.ai/t/what-are-claude-usage-credits)
53. [Use the Claude Agent SDK with your Claude plan | Claude Help Center](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
54. [Claude Haiku 4.5 - Claude Platform Docs](https://platform.claude.com/docs/en/models/haiku-4-5/overview)
55. [Claude Sonnet 5.5 - Claude Platform Docs](https://platform.claude.com/docs/en/models/sonnet-5-5/overview)
56. [Apple Silicon LLM Inference Optimization: The Complete Guide to Maximum Performance](https://blog.starmorph.com/blog/apple-silicon-llm-inference-optimization-guide)
57. [Ollama vs. llama.cpp vs. MLX with Qwen3.5 35B on Apple Silicon](https://antekapetanovic.com/blog/qwen3.5-apple-silicon-benchmark/)
58. [FoundationModel, context length, a…](https://developer.apple.com/forums/thread/806542)
59. [Introduction to Apple's FoundationModels: Limitations, Capabilities, Tools](https://www.natashatherobot.com/p/apple-foundation-models)
60. [apple foundation models context](https://infoq.com/news/2026/03/apple-foundation-models-context)
61. [Best Local LLMs for Mac in 2026 — M1 through M5 Tested](https://insiderllm.com/guides/best-local-llms-mac-2026/)
62. [Best Mac for Local AI: Every Apple Silicon Chip Ranked M1–M6](https://localaimaster.com/blog/apple-silicon-ai-buying-guide)
63. <https://flaviocopes.com/jev/>
64. [GitHub - Yinsongxu/LLM2Jev: Turn local language models into Jev-style structured decision models. Get results from text and images with prefill alone—no token-by-token decoding required.](https://github.com/Yinsongxu/LLM2Jev)
65. [GitHub - tapsin/jev-local: JEV-Local: System-1 decision engine for local LLMs. Mimics TypefAI JEV: structured choices only, no chatter, calibrated confidence. Works with Ollama, vLLM, llama.cpp, LM Studio. · GitHub](https://github.com/tapsin/jev-local)
66. [GitHub - githubnext/localjev · GitHub](https://github.com/githubnext/localjev)
67. [FluidAudio - Swift SDK for Speaker Diarization, VAD and ...](https://cocoapods.org/pods/FluidAudio)
