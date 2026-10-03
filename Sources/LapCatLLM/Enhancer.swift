import Foundation
import LapCatCore
import os

public enum EnhancerError: Error, Equatable, Sendable {
    case meetingNotFound(String)
    case templateNotFound(String)
    /// No transcript segments and no raw notes: there is nothing to write notes from.
    case nothingToEnhance
}

extension EnhancerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id): "Meeting \(id) not found"
        case .templateNotFound(let id): "Template \(id) not found"
        case .nothingToEnhance: "Nothing to enhance yet: no transcript and no notes"
        }
    }
}

/// Turns a meeting's raw notes + transcript into an enhanced note version (plan Step 7.4).
public actor Enhancer {
    /// Map-reduce window length.
    public static let windowMs = 10 * 60 * 1000
    /// Tokens reserved for the system prompt, template, notes framing and the reply.
    public static let promptOverheadTokens = 4_000
    /// Concurrent map calls for remote providers (local runs one at a time).
    public static let mapConcurrency = 4
    /// Transcript span sent to the classify and title prompts.
    static let openingMs = 5 * 60 * 1000

    private let store: Store
    private let router: LLMRouter
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.lapcat.app", category: "Enhancer")

    public init(store: Store, router: LLMRouter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.router = router
        self.now = now
    }

    /// Writes a new enhanced-note version for the meeting.
    /// - Parameters:
    ///   - templateID: a template row id, or `TemplateLibrary.autoID` to let the LLM pick (falls back to `general`).
    ///   - providerOverride: a provider id to use exclusively instead of the configured order.
    public func enhance(meetingID: String, templateID: String, providerOverride: String? = nil) async throws
        -> EnhancedNote
    {
        guard let meeting = try await store.meeting(id: meetingID) else {
            throw EnhancerError.meetingNotFound(meetingID)
        }
        let router = providerOverride.map { self.router.pinned(to: $0) } ?? self.router

        let allSegments = try await store.segments(meetingID: meetingID)
        let participants = try await store.participants(meetingID: meetingID)
        let rawNotes = try await store.rawNote(meetingID: meetingID)?.markdown ?? ""
        let snapshot = try await store.calendarSnapshot(meetingID: meetingID)
        let segments = TranscriptFormatter.selectedSegments(allSegments)
        guard !segments.isEmpty || !rawNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EnhancerError.nothingToEnhance
        }

        let context = Prompts.MeetingContext(
            title: meeting.title, date: meeting.startedAt,
            attendees: Self.attendees(snapshot: snapshot, participants: participants))
        let opening = TranscriptFormatter.forLLM(
            segments: segments.filter { $0.tStartMs < Self.openingMs }, participants: participants)
        let template = try await resolveTemplate(templateID, context: context, opening: opening, router: router)

        guard let head = await router.head(for: .enhance) else {
            throw LLMError.unavailable("no LLM provider available")
        }
        let transcript = TranscriptFormatter.forLLM(segments: segments, participants: participants)
        let estimate = (transcript.count + rawNotes.count) / 4
        let result: (response: LLMResponse, providerID: String)
        if estimate + Self.promptOverheadTokens > head.contextBudgetTokens {
            logger.info(
                "Map-reduce enhance: ~\(estimate) tokens > budget \(head.contextBudgetTokens) of \(head.id, privacy: .public)"
            )
            let summaries = try await summarizeWindows(
                segments, participants: participants, router: router,
                concurrency: head.id == LLMRouter.localProviderID ? 1 : Self.mapConcurrency)
            result = try await router.complete(
                LLMRequest(
                    task: .enhance, system: Prompts.enhanceSystem,
                    messages: [
                        .user(
                            Prompts.reduceUser(
                                meeting: context, templateName: template.name, templateBody: template.bodyMarkdown,
                                rawNotes: rawNotes, summaries: summaries))
                    ]))
        } else {
            result = try await router.complete(
                LLMRequest(
                    task: .enhance, system: Prompts.enhanceSystem,
                    messages: [
                        .user(
                            Prompts.enhanceUser(
                                meeting: context, templateName: template.name, templateBody: template.bodyMarkdown,
                                rawNotes: rawNotes, transcript: transcript))
                    ]))
        }

        let segmentIDs = Set(segments.compactMap(\.id))
        let markdown = Citations.normalizingBareSegmentIDs(
            Self.unfenced(result.response.text), validSegmentIDs: segmentIDs)
        let citations = Citations.parse(markdown, validSegmentIDs: segmentIDs)
        let note = try await store.insertEnhancedNote(
            EnhancedNote(
                meetingID: meetingID, templateID: template.id, provider: result.providerID,
                model: result.response.model,
                markdown: markdown, citationsJSON: Citations.json(citations),
                basedOnPass: TranscriptFormatter.selectedPass(allSegments), createdAt: now()))
        try await store.recordEnhancement(
            meetingID: meetingID, templateID: template.id,
            providerUsed: "\(result.providerID):\(result.response.model)", now: now())

        if snapshot == nil, MeetingTitle.isDefault(meeting.title) {
            await autoTitle(meeting: meeting, attendees: context.attendees, opening: opening, router: router)
        }
        return note
    }

    // MARK: - Steps

    /// `auto` asks the classifier; any classify failure or unknown answer falls back to `general`.
    private func resolveTemplate(_ id: String, context: Prompts.MeetingContext, opening: String, router: LLMRouter)
        async throws -> Template
    {
        guard id == TemplateLibrary.autoID else {
            guard let template = try await store.template(id: id) else { throw EnhancerError.templateNotFound(id) }
            return template
        }
        let templates = try await store.templates()
        struct Choice: Decodable, Sendable { var template_id: String }
        do {
            let choice = try await router.completeJSON(
                LLMRequest(
                    task: .classify, system: Prompts.classifySystem(templateIDs: templates.map(\.id)),
                    messages: [.user(Prompts.classifyUser(meeting: context, openingTranscript: opening))],
                    maxTokens: 256),
                as: Choice.self)
            if let template = templates.first(where: { $0.id == choice.value.template_id }) { return template }
            logger.warning(
                "Classifier picked unknown template \(choice.value.template_id, privacy: .public); using general")
        } catch {
            logger.warning(
                "Template classification failed: \(error.localizedDescription, privacy: .public); using general")
        }
        guard let general = templates.first(where: { $0.id == TemplateLibrary.generalID }) else {
            throw EnhancerError.templateNotFound(TemplateLibrary.generalID)
        }
        return general
    }

    /// Map step: one `chunkSummarySystem` call per 10-minute window, joined in window order.
    private func summarizeWindows(
        _ segments: [Segment], participants: [Participant], router: LLMRouter, concurrency: Int
    ) async throws -> String {
        let windows = Self.windows(segments)
        var summaries = [String?](repeating: nil, count: windows.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            func submit() {
                let index = next
                let transcript = TranscriptFormatter.forLLM(
                    segments: windows[index].segments, participants: participants)
                group.addTask {
                    let request = LLMRequest(
                        task: .enhance, system: Prompts.chunkSummarySystem, messages: [.user(transcript)],
                        maxTokens: 2048)
                    return (index, try await router.complete(request).response.text)
                }
                next += 1
            }
            while next < min(concurrency, windows.count) { submit() }
            while let (index, text) = try await group.next() {
                summaries[index] = text
                if next < windows.count { submit() }
            }
        }
        return zip(windows, summaries).map { window, summary in
            let start = TranscriptFormatter.timestamp(ms: window.index * Self.windowMs)
            let end = TranscriptFormatter.timestamp(ms: (window.index + 1) * Self.windowMs)
            return "## \(start)–\(end)\n\(summary ?? "")"
        }.joined(separator: "\n\n")
    }

    /// Non-empty 10-minute windows by `t_start_ms`, in order.
    static func windows(_ segments: [Segment]) -> [(index: Int, segments: [Segment])] {
        Dictionary(grouping: segments) { max(0, $0.tStartMs) / windowMs }
            .sorted { $0.key < $1.key }
            .map { (index: $0.key, segments: $0.value) }
    }

    /// FR-5.5: titles an untitled meeting without a calendar event. Failures only log.
    private func autoTitle(meeting: Meeting, attendees: [String], opening: String, router: LLMRouter) async {
        struct Title: Decodable, Sendable { var title: String }
        do {
            let reply = try await router.completeJSON(
                LLMRequest(
                    task: .classify, system: Prompts.titleSystem,
                    messages: [.user(Prompts.titleUser(attendees: attendees, openingTranscript: opening))],
                    maxTokens: 128),
                as: Title.self)
            let title = reply.value.title
                .components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet.whitespaces.union(["\"", "'", "“", "”"]))
            guard !title.isEmpty else { return }
            try await store.replaceMeetingTitle(id: meeting.id, expected: meeting.title, with: title, now: now())
        } catch {
            logger.warning("Auto-title failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// Calendar attendees, then named participants (diarization clusters and unconfirmed LLM suggestions excluded).
    static func attendees(snapshot: CalendarSnapshot?, participants: [Participant]) -> [String] {
        var seen = Set<String>()
        let names =
            (snapshot?.attendees ?? [])
            + participants.filter { $0.source != .cluster && $0.source != .llmSuggested }.map(\.displayName)
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Removes one code fence wrapping the whole reply despite the "no code fences" rule.
    static func unfenced(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, lines.first!.hasPrefix("```"), lines.last!.trimmingCharacters(in: .whitespaces) == "```"
        else {
            return trimmed
        }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
