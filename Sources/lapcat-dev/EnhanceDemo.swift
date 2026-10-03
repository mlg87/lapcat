import Foundation
import LapCatCore
import LapCatLLM

/// `lapcat-dev enhance-demo [--template ID] [--model M]`: enhances a canned short meeting in a temp
/// database through the real Claude CLI and prints the note plus citation/raw-line checks.
enum EnhanceDemo {
    static let rawNotes = """
        pricing: enterprise tier $40/seat?
        - [ ] send deck to Priya
        """

    static let transcript: [(Channel, Int, String)] = [
        (.mic, 0, "Thanks for making time, Priya. I wanted to go over the enterprise pricing before Friday."),
        (.system, 6_000, "Sure. Our finance team thinks forty dollars per seat is fine if SSO is included."),
        (.mic, 14_000, "SSO is included in the enterprise tier, so forty per seat works for us."),
        (.system, 21_000, "Great. Can you send me the deck so I can share it with our CFO?"),
        (.mic, 27_000, "Yes, I'll send the deck by Thursday."),
        (.system, 33_000, "One open question is whether the annual contract can start in November."),
        (.mic, 40_000, "I need to check with our legal team and will get back to you on the November start."),
    ]

    static func run(_ arguments: [String]) async -> Int32 {
        var templateID = TemplateLibrary.autoID
        var model: String?
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--template": templateID = iterator.next() ?? templateID
            case "--model": model = iterator.next()
            default:
                FileHandle.standardError.write(
                    Data("usage: lapcat-dev enhance-demo [--template ID] [--model M]\n".utf8))
                return 64
            }
        }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "lapcat-enhance-demo-\(UUID().uuidString)")
            let store = try Store(databaseURL: dir.appendingPathComponent("lapcat.sqlite"))
            try await TemplateLibrary.sync(store: store, customDirectory: dir.appendingPathComponent("templates"))
            let started = Date()
            let meeting = try await store.createMeeting(title: defaultTitle(started), startedBy: .manual, now: started)
            let priya = try await store.upsertParticipant(meetingID: meeting.id, name: "Priya Shah", source: .zoomAX)
            try await store.appendSegments(
                transcript.map { channel, ms, text in
                    Segment(
                        meetingID: meeting.id, channel: channel, tStartMs: ms, tEndMs: ms + 5_000, text: text,
                        participantID: channel == .system ? priya.id : nil, pass: .final)
                })
            try await store.saveRawNote(meetingID: meeting.id, markdown: rawNotes)

            let models: [LLMTask: String] = [
                .enhance: model ?? "sonnet", .chat: model ?? "sonnet", .classify: model ?? "haiku",
            ]
            let router = LLMRouter(providers: [ClaudeCLIProvider(models: models, claudePath: nil)], offlineOnly: false)
            let clock = ContinuousClock.now
            let note = try await Enhancer(store: store, router: router).enhance(
                meetingID: meeting.id, templateID: templateID)
            let elapsed = ContinuousClock.now - clock
            let title = try await store.meeting(id: meeting.id)?.title ?? "?"

            print("database: \(dir.path)")
            print(
                "template: \(note.templateID)  provider: \(note.provider)  model: \(note.model)  v\(note.version)  \(elapsed)"
            )
            print("title: \(meeting.title) -> \(title)")
            print("----- markdown -----\n\(note.markdown)\n--------------------")
            print("citations_json: \(note.citationsJSON)")
            let kinds = LineAttribution.classify(enhanced: note.markdown, raw: rawNotes)
            let lines = note.markdown.split(separator: "\n", omittingEmptySubsequences: false)
            for (kind, line) in zip(kinds, lines) where kind == .mine { print("mine: \(line)") }
            let cited = note.markdown.contains("[[s:")
            let verbatim = rawNotes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { note.markdown.contains($0) }
            print("has [[s: citations: \(cited)")
            print("raw lines verbatim: \(verbatim)")
            return cited && !verbatim.isEmpty ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("enhance-demo failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func defaultTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Note " + formatter.string(from: date)
    }
}

/// `lapcat-dev templates`: lists the built-in templates and the resource bundle they came from.
enum TemplatesCommand {
    static func run() -> Int32 {
        do {
            let templates = try TemplateLibrary.builtinTemplates()
            print("resource bundle: \(TemplateLibrary.resourceBundlePath)")
            for template in templates {
                print("\(template.id)\t\(template.name)\t\(template.description)")
            }
            return templates.isEmpty ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data("templates failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
