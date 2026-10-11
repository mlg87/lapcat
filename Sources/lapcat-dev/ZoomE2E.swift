import AVFoundation
import AppKit
import Foundation
import LapCatAudio
import LapCatCore
import LapCatLLM
import LapCatSession
import LapCatSpeakers
import LapCatSpeech
import UserNotifications
import os

/// `lapcat-dev zoom-e2e [--skip-stt] [--keep] [--record-fixtures <dir>] [--pipeline-timeout 900]`
///
/// Runs the real Zoom path end to end (#61): opens the user's meeting in the Zoom desktop client,
/// accepts LapCat's detection prompt, lets a Meeting SDK bot (`scripts/zoom-e2e/bot.ts`) speak a
/// `say`-generated script, quits Zoom, waits for auto-stop and the post-meeting pipeline, then checks
/// the speaker events, participants, named segments, transcript and audio files. Along the way it
/// records the accessibility trees and Core Audio process list the deterministic suite replays.
/// Everything is real except the notifier (a CLI has no `UNUserNotificationCenter`) and the data
/// directory (a fresh one under /tmp).
enum ZoomE2E {
    static let usage =
        "usage: lapcat-dev zoom-e2e [--skip-stt] [--keep] [--record-fixtures <dir>] [--pipeline-timeout 900]"

    static let script = """
        Hello from the LapCat test bot. The quarterly budget review is scheduled for Thursday afternoon. \
        Please remember to upload the final spreadsheet before the deadline. Our customer in Lisbon confirmed \
        the renewal for another twelve months. The new onboarding checklist reduced support tickets by half. \
        That concludes the automated transcription check.
        """

    static let zoomBundleID = "us.zoom.xos"
    static let zoomApp = URL(fileURLWithPath: "/Applications/zoom.us.app")
    static let hostName = "LapCat Host"
    /// Zoom's join dialogs, answered when the README's Zoom settings are not applied. Titles unverified:
    /// check them against `failure-ax.json` when a dialog stays open.
    static let joinButtonPattern =
        #"^(Join with Computer Audio|Join Audio by Computer|Join without Video|Join with Video)$"#

    struct Options {
        var skipSTT = false
        var keep = false
        var recordFixtures: URL?
        var pipelineTimeout: Duration = .seconds(900)
    }

    struct Environment {
        var meetingNumber: String
        var passwordToken: String
        var passcode: String
        var clientID: String
        var clientSecret: String
        var botName: String
    }

    struct Failure: Error {
        var message: String
    }

    struct Check: Codable {
        var id: String
        var name: String
        var pass: Bool
        var detail: String
    }

    struct Report: Codable {
        var runDirectory: String
        var zoomVersion: String
        var botName: String
        var speechSeconds: Double
        var detectSeconds: Double?
        var autoStopSeconds: Double?
        var nameExposedBy: String?
        var talkingObservation: String?
        var failure: String?
        var checks: [Check] = []
    }

    @MainActor static func run(_ arguments: [String]) async -> Int32 {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--skip-stt": options.skipSTT = true
            case "--keep": options.keep = true
            case "--record-fixtures":
                guard let path = iterator.next() else { return usageError() }
                options.recordFixtures = URL(fileURLWithPath: path, isDirectory: true)
            case "--pipeline-timeout":
                guard let seconds = iterator.next().flatMap(Int.init) else { return usageError() }
                options.pipelineTimeout = .seconds(seconds)
            default: return usageError()
            }
        }
        let environment: Environment
        do {
            environment = try await preflight(options)
        } catch let failure as Failure {
            FileHandle.standardError.write(Data("zoom-e2e: \(failure.message)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("zoom-e2e: \(error)\n".utf8))
            return 2
        }
        do {
            let run = try ZoomE2ERun(options: options, environment: environment)
            // Last preflight check: it needs the run's settings to know which engine the final pass uses.
            if !options.skipSTT, let model = run.missingFinalModel {
                run.discard()
                FileHandle.standardError.write(
                    Data("zoom-e2e: download the final-pass model \(model) in LapCat first, or pass --skip-stt\n".utf8))
                return 2
            }
            return await run.execute()
        } catch {
            FileHandle.standardError.write(Data("zoom-e2e: cannot set up the run: \(error)\n".utf8))
            return 1
        }
    }

    private static func usageError() -> Int32 {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 64
    }

    /// Every precondition a run needs; each failure is one line naming the fix.
    @MainActor private static func preflight(_ options: Options) async throws -> Environment {
        guard AXElement.isProcessTrusted else {
            throw Failure(message: "grant Accessibility to this terminal (System Settings → Privacy & Security)")
        }
        let env = ProcessInfo.processInfo.environment
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else { throw Failure(message: "set \(name) (.env.zoom-e2e)") }
            return value
        }
        let joinURL = try required("LAPCAT_ZOOM_E2E_JOIN_URL")
        let passcode = try required("LAPCAT_ZOOM_E2E_PASSCODE")
        let clientID = try required("LAPCAT_ZOOM_SDK_CLIENT_ID")
        let clientSecret = try required("LAPCAT_ZOOM_SDK_CLIENT_SECRET")
        guard let components = URLComponents(string: joinURL),
            let number = joinURL.firstMatch(of: /\/j\/(\d+)/)?.1,
            let token = components.queryItems?.first(where: { $0.name == "pwd" })?.value
        else {
            throw Failure(
                message: "LAPCAT_ZOOM_E2E_JOIN_URL must be an invite link like https://…zoom.us/j/<n>?pwd=<token>")
        }
        guard FileManager.default.fileExists(atPath: zoomApp.path) else {
            throw Failure(message: "install the Zoom desktop client in /Applications")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: zoomBundleID).isEmpty else {
            throw Failure(message: "quit Zoom first")
        }
        let cwd = FileManager.default.currentDirectoryPath
        guard FileManager.default.fileExists(atPath: "\(cwd)/scripts/zoom-e2e/bot.ts"),
            FileManager.default.fileExists(atPath: "\(cwd)/node_modules/playwright")
        else {
            throw Failure(message: "run from the repo root after npm install && npx playwright install chromium")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw Failure(message: "grant Microphone to this terminal (System Settings → Privacy & Security)")
        }
        for tool in ["/usr/bin/say", "/usr/bin/afconvert"] where !FileManager.default.fileExists(atPath: tool) {
            throw Failure(message: "\(tool) is missing")
        }
        return Environment(
            meetingNumber: String(number), passwordToken: token, passcode: passcode, clientID: clientID,
            clientSecret: clientSecret,
            botName: env["LAPCAT_ZOOM_E2E_BOT_NAME"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "LapCat Bot")
    }
}

/// Appends every step line to `log.txt` and prints it.
final class RunLog: Sendable {
    private let handle: FileHandle
    private let lock = OSAllocatedUnfairLock()

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func callAsFunction(_ line: String) {
        let stamped = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)"
        lock.withLock {
            print(stamped)
            handle.write(Data((stamped + "\n").utf8))
        }
    }
}

/// Logs prompts instead of posting them: `UNUserNotificationCenter` needs an app bundle.
struct LoggingNotifier: PromptNotifier {
    let log: RunLog

    func activate(delegate: any UNUserNotificationCenterDelegate) {}
    func postPrompt(id: String, title: String, body: String) { log("notification: \(title) — \(body)") }
    func postInfo(id: String, title: String, body: String) { log("notification: \(title) — \(body)") }
    func removeDelivered(ids: [String]) {}
}

/// The bot's stdout events, collected off its pipe.
final class BotEvents: @unchecked Sendable {
    // JSON objects are `[String: Any]`; every access goes through the lock.
    private let state = OSAllocatedUnfairLock(uncheckedState: (buffer: Data(), events: [[String: Any]]()))

    func append(_ data: Data, log: RunLog) {
        let lines: [Data] = state.withLockUnchecked { state in
            state.buffer.append(data)
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(state.buffer[..<newline])
                state.buffer.removeSubrange(...newline)
            }
            return lines
        }
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            log("bot: \(String(decoding: line, as: UTF8.self))")
            state.withLockUnchecked { $0.events.append(object) }
        }
    }

    func first(_ name: String) -> [String: Any]? {
        state.withLockUnchecked { $0.events.first { $0["event"] as? String == name } }
    }
}

@MainActor final class ZoomE2ERun {
    static let settingsSuite = "lapcat.zoom-e2e"

    private let options: ZoomE2E.Options
    private let environment: ZoomE2E.Environment
    private let runDirectory: URL
    private let dataDirectory: URL
    private let botDirectory: URL
    private let fixturesDirectory: URL
    private let log: RunLog
    private let paths: Paths
    private let zoomVersion: String
    private var report: ZoomE2E.Report
    private let settings: AppSettings
    private let store: Store
    private let session: SessionController
    private let pipeline: PostMeetingPipeline
    private let detection: DetectionCoordinator
    private var bot: Process?
    private var botInput: Pipe?
    private let botEvents = BotEvents()

    init(options: ZoomE2E.Options, environment: ZoomE2E.Environment) throws {
        self.options = options
        self.environment = environment
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        runDirectory = URL(fileURLWithPath: "/tmp/lapcat-zoom-e2e/\(stamp)", isDirectory: true)
        dataDirectory = runDirectory.appendingPathComponent("data", isDirectory: true)
        botDirectory = runDirectory.appendingPathComponent("bot", isDirectory: true)
        fixturesDirectory = runDirectory.appendingPathComponent("fixtures", isDirectory: true)
        for directory in [dataDirectory, botDirectory, fixturesDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Reuse the app's downloaded models rather than fetching them into the scratch directory.
        try FileManager.default.createSymbolicLink(
            at: dataDirectory.appendingPathComponent("models"), withDestinationURL: Paths.standard.models)
        paths = Paths(root: dataDirectory)
        try FileManager.default.createDirectory(at: paths.audioRoot, withIntermediateDirectories: true)
        log = try RunLog(url: runDirectory.appendingPathComponent("log.txt"))
        let version = Bundle(url: ZoomE2E.zoomApp)?.infoDictionary?["CFBundleShortVersionString"] as? String
        zoomVersion = version?.split(separator: " ").first.map(String.init) ?? "unknown"
        report = ZoomE2E.Report(
            runDirectory: runDirectory.path, zoomVersion: zoomVersion, botName: environment.botName, speechSeconds: 0)

        let defaults = UserDefaults(suiteName: Self.settingsSuite)!
        defaults.removePersistentDomain(forName: Self.settingsSuite)
        settings = AppSettings(defaults: defaults)
        settings.detectEnabled = true
        settings.detectBundleIDs = [ZoomE2E.zoomBundleID]
        settings.detectUseCalendarSignal = false
        settings.detectUseBrowserTabSignal = false
        settings.speakersAdaptersEnabled = true
        settings.audioTapScope = "app"
        settings.userDisplayName = ZoomE2E.hostName
        settings.llmOfflineOnly = true

        store = try Store(databaseURL: paths.database)
        let speechServices = SpeechServices()
        var sessionDependencies = SessionDependencies.live
        sessionDependencies.paths = paths
        session = SessionController(
            store: store, settings: settings, speech: speechServices, dependencies: sessionDependencies)
        let speechConfig = session.speechConfig
        let templateID = settings.templateDefaultID
        pipeline = PostMeetingPipeline(
            store: store, speech: speechServices, paths: paths,
            // No LLM steps: quickEnhance, suggestSpeakers and enhance need a provider.
            steps: options.skipSTT
                ? [.nameMap, .reindex]
                : [.finalSTTMic, .finalSTTSystem, .diarize, .nameMap, .echoDedup, .mergeLive, .reindex],
            config: {
                PipelineConfig(
                    speech: speechConfig, offlineOnly: true, retention: .thirtyDays, meName: ZoomE2E.hostName,
                    defaultTemplateID: templateID, autoExportFolder: nil,
                    router: LLMRouter(providers: [], offlineOnly: true))
            })
        var detectionDependencies = DetectionDependencies.live
        detectionDependencies.notifier = LoggingNotifier(log: log)
        detection = DetectionCoordinator(session: session, settings: settings, dependencies: detectionDependencies)
    }

    /// The final-pass model file the run's settings need but `Paths.standard.models` lacks.
    var missingFinalModel: String? {
        guard let model = EngineSelector(config: session.speechConfig).finalEngine().requiredModelFile,
            !FileManager.default.fileExists(atPath: paths.models.appendingPathComponent(model).path)
        else { return nil }
        return model
    }

    /// Removes the run directory of a run that never started.
    func discard() {
        try? FileManager.default.removeItem(at: runDirectory)
    }

    func execute() async -> Int32 {
        log("run directory \(runDirectory.path) · Zoom \(zoomVersion) · bot \"\(environment.botName)\"")
        let exitCode: Int32
        do {
            try await steps()
            exitCode = report.checks.allSatisfy(\.pass) ? 0 : 1
        } catch {
            let message = (error as? ZoomE2E.Failure)?.message ?? String(describing: error)
            log("FAILED: \(message)")
            report.failure = message
            await writeFailureTree()
            exitCode = 1
        }
        await stopBot()
        await quitZoom()
        writeReport()
        printTable()
        if let destination = options.recordFixtures { copyFixtures(to: destination) }
        if !options.keep { try? FileManager.default.removeItem(at: dataDirectory) }
        print("run directory: \(runDirectory.path)")
        return exitCode
    }

    // MARK: Steps

    private func steps() async throws {
        let speech = try makeSpeech()
        report.speechSeconds = speech.seconds

        let session = session
        let store = store
        let detection = detection
        let pipeline = pipeline
        session.onEnded = { meetingID in
            detection.sessionEnded()
            Task { await pipeline.enqueue(meetingID) }
        }
        detection.start()

        // 1. Open the meeting in the desktop client.
        let opened = Date()
        let joinURL = URL(
            string:
                "zoommtg://zoom.us/join?action=join&confno=\(environment.meetingNumber)&pwd=\(environment.passwordToken)"
        )!
        log("opening \(joinURL.absoluteString.replacingOccurrences(of: environment.passwordToken, with: "…"))")
        NSWorkspace.shared.open(joinURL)
        try await waitFor("Zoom to launch", timeout: .seconds(60)) { self.zoomApplication != nil }
        let joinDialogs = Task { await self.answerJoinDialogs(for: .seconds(30)) }

        // 2. Detection prompt → accept → recording with an app-scoped tap.
        try await waitFor("the Zoom detection prompt", timeout: .seconds(90)) {
            detection.pending?.source?.bundleID == ZoomE2E.zoomBundleID
        }
        joinDialogs.cancel()
        let detectedPID = detection.pending?.source?.pid
        report.detectSeconds = Date().timeIntervalSince(opened)
        log("prompt after \(Int(report.detectSeconds ?? 0)) s for pid \(detectedPID.map(String.init) ?? "?")")
        detection.accept()
        try await waitFor("recording to start", timeout: .seconds(45)) {
            if case .recording = session.state { true } else { false }
        }
        guard let meetingID = session.meetingID else { throw ZoomE2E.Failure(message: "no meeting id") }
        try writeJSON(
            AudioProcessRegistry.processes(), to: fixturesDirectory.appendingPathComponent("zoom-processes.json"))
        let scopeOK: Bool
        if case .app(_, let appPID) = session.captureScope, appPID == detectedPID {
            scopeOK = true
        } else {
            scopeOK = false
        }
        check("S1", "app-scoped tap on the detected Zoom pid", scopeOK, String(describing: session.captureScope))
        try await Task.sleep(for: .seconds(10))
        let warning = session.warning
        let captureWarning = warning.map { $0.hasPrefix("System audio") || $0.hasPrefix("LapCat lacks") } ?? false
        check("S2", "no capture warning after 10 s", !captureWarning, warning ?? "none")

        // 3. The bot joins and speaks.
        try startBot(audio: speech.file)
        try await waitFor("the bot to join audio", timeout: .seconds(90)) {
            if let error = self.botEvents.first("error") {
                throw ZoomE2E.Failure(message: "bot: \(error["message"] as? String ?? "unknown error")")
            }
            return self.botEvents.first("audio-joined") != nil
        }
        let audioAt =
            (botEvents.first("audio-joined")?["at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? Date()

        // 4. Accessibility trees while the bot talks and after it stops.
        guard let zoomPID = zoomApplication?.processIdentifier else { throw ZoomE2E.Failure(message: "Zoom quit") }
        try await sleep(until: audioAt.addingTimeInterval(6))
        let talking = await AXQueue.shared.run { AXTreeCapture.roots(pid: zoomPID, selectors: .zoomDefault) }
        try writeJSON(talking.map(\.withoutFrames), to: fixture("talking"))
        let observation = SpeakerSelectors.zoomDefault.observation(from: talking)
        report.talkingObservation = "\(observation)"
        log("zoomDefault on the talking tree: \(observation)")
        if contains(environment.botName, in: talking) {
            report.nameExposedBy = "meeting window"
        } else {
            log("bot name not in the meeting window tree; opening the Participants panel")
            await pressButton(in: zoomPID, matching: #"^Participants"#)
            try await Task.sleep(for: .seconds(3))
            let panel = await AXQueue.shared.run { AXTreeCapture.roots(pid: zoomPID, selectors: .zoomDefault) }
            try writeJSON(panel.map(\.withoutFrames), to: fixture("talking-panel"))
            report.nameExposedBy = contains(environment.botName, in: panel) ? "participants panel" : "nothing"
            log("participants panel exposes the bot name: \(report.nameExposedBy ?? "nothing")")
        }
        try await sleep(until: audioAt.addingTimeInterval(report.speechSeconds + 8))
        let silent = await AXQueue.shared.run { AXTreeCapture.roots(pid: zoomPID, selectors: .zoomDefault) }
        try writeJSON(silent.map(\.withoutFrames), to: fixture("silent"))
        log("zoomDefault on the silent tree: \(SpeakerSelectors.zoomDefault.observation(from: silent))")

        // 5. The bot leaves, then Zoom quits: auto-stop starts counting from the mic release.
        try await sleep(until: audioAt.addingTimeInterval(report.speechSeconds + 15))
        await stopBot()
        let quitAt = Date()
        await quitZoom()

        // 6. Auto-stop.
        try await waitFor("auto-stop", timeout: .seconds(120)) { session.state == .idle }
        report.autoStopSeconds = Date().timeIntervalSince(quitAt)
        log("auto-stop \(Int(report.autoStopSeconds ?? 0)) s after Zoom quit")
        guard let ended = try await store.meeting(id: meetingID), ended.endedAt != nil else {
            throw ZoomE2E.Failure(message: "meeting \(meetingID) has no end time")
        }

        // 7. Post-meeting pipeline.
        try await waitFor("the pipeline", timeout: options.pipelineTimeout) {
            guard let meeting = try await store.meeting(id: meetingID) else { return false }
            if meeting.status == .error {
                throw ZoomE2E.Failure(message: "pipeline error: \(meeting.errorMessage ?? "unknown")")
            }
            return meeting.status == .ready
        }

        // 8. Checks.
        try await evaluate(store: store, meetingID: meetingID, selfName: observation.selfName)
    }

    private func evaluate(store: Store, meetingID: String, selfName: String?) async throws {
        let bot = environment.botName
        guard let meeting = try await store.meeting(id: meetingID) else { return }
        let lengthMs = Int(((meeting.endedAt ?? Date()).timeIntervalSince(meeting.startedAt)) * 1000)
        let events = try await store.speakerEvents(meetingID: meetingID)
        let botRows = events.filter { $0.displayName == bot && $0.source == .zoomAX }
        let spokenMs = botRows.reduce(0) { $0 + (($1.tEndMs ?? lengthMs) - $1.tStartMs) }
        let neededMs = Int(report.speechSeconds * 500)
        check(
            "D1", "bot speaker events cover half the speech", !botRows.isEmpty && spokenMs >= neededMs,
            "\(botRows.count) events, \(spokenMs) ms of \(neededMs) ms needed · talking fixture \(fixture("talking").path)"
        )

        let hostNames = Set([ZoomE2E.hostName] + (selfName.map { [$0] } ?? []))
        let hostEvents = events.filter { hostNames.contains($0.displayName) }
        check(
            "D2", "no speaker event for the host", hostEvents.isEmpty,
            "host names \(hostNames.sorted()) · \(hostEvents.count) events")

        let participants = try await store.participants(meetingID: meetingID)
        let botParticipant = participants.first { $0.displayName == bot && $0.source == .zoomAX }
        let me = participants.filter(\.isMe)
        check(
            "D3", "bot is a zoom_ax participant, exactly one me", botParticipant != nil && me.count == 1,
            participants.map { "\($0.displayName) (\($0.source.rawValue)\($0.isMe ? ", me" : ""))" }
                .joined(separator: ", "))

        if !options.skipSTT {
            let system = try await store.segments(meetingID: meetingID, pass: .final).filter { $0.channel == .system }
            let named = system.filter { $0.participantID != nil && $0.participantID == botParticipant?.id }
            let share = system.isEmpty ? 0 : Double(named.count) / Double(system.count)
            check(
                "F1", "≥ 85 % of final system segments named the bot", !system.isEmpty && share >= 0.85,
                "\(named.count)/\(system.count) = \(Int(share * 100)) %")

            func words(_ text: String) -> Set<String> {
                Set(
                    text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
                        .filter { $0.count >= 4 })
            }
            let expected = words(ZoomE2E.script)
            let heard = words(system.map(\.text).joined(separator: " "))
            let recall = Double(expected.intersection(heard).count) / Double(expected.count)
            check(
                "F2", "≥ 60 % of the script's words transcribed", recall >= 0.6,
                "\(Int(recall * 100)) % · missing \(expected.subtracting(heard).sorted().prefix(12).joined(separator: " "))"
            )
        }

        let files = try await store.audioFiles(meetingID: meetingID)
        let mic = files.first { $0.channel == .mic }?.durationMs
        let system = files.first { $0.channel == .system }?.durationMs
        let durationsOK: Bool
        if let mic, let system {
            durationsOK = abs(mic - system) <= 2000 && min(mic, system) >= lengthMs - 3000
        } else {
            durationsOK = false
        }
        check(
            "F3", "both channels span the recording (±2 s)", durationsOK,
            "mic \(mic.map(String.init) ?? "-") ms, system \(system.map(String.init) ?? "-") ms, recording \(lengthMs) ms"
        )
    }

    // MARK: Bot

    private func makeSpeech() throws -> (file: URL, seconds: Double) {
        let aiff = botDirectory.appendingPathComponent("script.aiff")
        let wav = botDirectory.appendingPathComponent("script.wav")
        try runTool("/usr/bin/say", ["-v", "Samantha", "-r", "170", "-o", aiff.path, ZoomE2E.script])
        try runTool("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@48000", "-c", "1", aiff.path, wav.path])
        let file = try AVAudioFile(forReading: wav)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        log("script: \(String(format: "%.1f", seconds)) s of speech in \(wav.path)")
        return (wav, seconds)
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ZoomE2E.Failure(message: "\(path) exited \(process.terminationStatus)")
        }
    }

    private func startBot(audio: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "npx", "tsx", "scripts/zoom-e2e/bot.ts", "--meeting", environment.meetingNumber, "--passcode",
            environment.passcode, "--name", environment.botName, "--audio", audio.path, "--artifacts",
            botDirectory.path,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        let stderrURL = botDirectory.appendingPathComponent("bot.log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        let events = botEvents
        let log = log
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { events.append(data, log: log) }
        }
        try process.run()
        bot = process
        botInput = stdin
        log("bot started (pid \(process.processIdentifier)); its log is \(stderrURL.path)")
    }

    private func stopBot() async {
        guard let bot, bot.isRunning else { return }
        botInput?.fileHandleForWriting.write(Data("leave\n".utf8))
        let deadline = Date().addingTimeInterval(15)
        while bot.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
        if bot.isRunning {
            log("bot did not leave within 15 s; terminating it")
            bot.terminate()
        }
        self.bot = nil
    }

    // MARK: Zoom

    private var zoomApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ZoomE2E.zoomBundleID).first
    }

    private func quitZoom() async {
        guard let zoom = zoomApplication else { return }
        zoom.terminate()
        let deadline = Date().addingTimeInterval(10)
        while !zoom.isTerminated, Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
        if !zoom.isTerminated {
            log("Zoom did not quit within 10 s; force-quitting it")
            zoom.forceTerminate()
        }
    }

    /// Presses Zoom's audio/video join buttons once a second, for setups where Zoom still asks.
    private func answerJoinDialogs(for duration: Duration) async {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let pid = zoomApplication?.processIdentifier,
                let title = await pressButton(in: pid, matching: ZoomE2E.joinButtonPattern)
            {
                log("pressed Zoom's \"\(title)\" button")
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Presses the first button whose title matches `pattern` in any Zoom window; returns its title.
    @discardableResult
    private func pressButton(in pid: pid_t, matching pattern: String) async -> String? {
        await AXQueue.shared.run {
            guard let regex = try? Regex(pattern) else { return nil }
            for window in AXElement.application(pid: pid).allWindows {
                let button = window.firstDescendant(depth: 12) { element in
                    guard element.role == "AXButton" else { return false }
                    let label = element.title ?? element.axDescription ?? ""
                    return label.firstMatch(of: regex) != nil
                }
                if let button, button.press() { return button.title ?? button.axDescription ?? "?" }
            }
            return nil
        }
    }

    private func contains(_ name: String, in trees: [AXNodeSnapshot]) -> Bool {
        trees.flatMap(\.flattened).contains { node in
            [node.title, node.description, node.value].contains { $0?.contains(name) == true }
        }
    }

    // MARK: Output

    private func fixture(_ kind: String) -> URL {
        fixturesDirectory.appendingPathComponent("zoom-\(zoomVersion)-\(kind).json")
    }

    private func writeJSON(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        log("wrote \(url.path)")
    }

    private func writeFailureTree() async {
        guard let pid = zoomApplication?.processIdentifier else { return }
        let trees = await AXQueue.shared.run { AXTreeCapture.roots(pid: pid, selectors: .zoomDefault) }
        try? writeJSON(trees.map(\.withoutFrames), to: runDirectory.appendingPathComponent("failure-ax.json"))
    }

    private func writeReport() {
        try? writeJSON(report, to: runDirectory.appendingPathComponent("report.json"))
    }

    private func check(_ id: String, _ name: String, _ pass: Bool, _ detail: String) {
        report.checks.append(ZoomE2E.Check(id: id, name: name, pass: pass, detail: detail))
        log("\(id) \(pass ? "pass" : "FAIL") — \(name): \(detail)")
    }

    private func printTable() {
        print("\n| check | result | detail |\n|---|---|---|")
        for check in report.checks {
            print("| \(check.id) \(check.name) | \(check.pass ? "pass" : "FAIL") | \(check.detail) |")
        }
        if let detect = report.detectSeconds { print("detectSeconds: \(String(format: "%.1f", detect))") }
        if let stop = report.autoStopSeconds { print("autoStopSeconds: \(String(format: "%.1f", stop))") }
        if let failure = report.failure { print("failure: \(failure)") }
    }

    private func copyFixtures(to destination: URL) {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for file in try FileManager.default.contentsOfDirectory(
                at: fixturesDirectory, includingPropertiesForKeys: nil)
            {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: file, to: target)
            }
            log("fixtures copied to \(destination.path)")
        } catch {
            log("cannot copy fixtures to \(destination.path): \(error)")
        }
    }

    // MARK: Waiting

    private func waitFor(
        _ what: String, timeout: Duration, _ condition: @MainActor () async throws -> Bool
    ) async throws {
        log("waiting for \(what) (up to \(timeout.components.seconds) s)")
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ZoomE2E.Failure(message: "timed out waiting for \(what)")
    }

    private func sleep(until date: Date) async throws {
        let interval = date.timeIntervalSinceNow
        if interval > 0 { try await Task.sleep(for: .seconds(interval)) }
    }
}
