import Foundation
import LapCatCore

/// Chat over one meeting, a folder, or all meetings (PRD FR-7). Answers stream from `LLMRouter` (task
/// `.chat`); the user message is persisted before the request and the assistant message, with its parsed
/// citations, once the stream completes.
public final class ChatService: Sendable {
    public static let chatSystem =
        "You answer questions about the user's meetings using only the provided context. Cite every claim with [[s:ID]] (single meeting) or [[m:MEETING_ID#s:ID]] (multiple meetings). If the context does not contain the answer, say so. Be concise."

    /// Prior thread messages sent with each question.
    static let historyLimit = 10
    /// Tokens of the provider budget kept free for the answer.
    static let answerReserveTokens = 4_000
    /// Budget used when no provider is available to ask (the request then fails in the router anyway).
    static let fallbackBudgetTokens = 24_000
    static let searchHitLimit = 40
    static let neighbourCount = 2
    static let personLineLimit = 20
    static let noteExcerptChars = 4_000
    static let omittedMarker = "(earlier transcript omitted)"

    private let store: Store
    private let router: LLMRouter
    private let maxAnswerTokens: Int

    public init(store: Store, router: LLMRouter, maxAnswerTokens: Int = 2_048) {
        self.store = store
        self.router = router
        self.maxAnswerTokens = maxAnswerTokens
    }

    /// Asks `question` in the thread of `scope`/`scopeRef` (meeting id for `.meeting`, folder id for
    /// `.folder`, nil for `.global`) and streams the answer's text deltas. `dateRange` restricts
    /// folder/global context to meetings started in that range.
    public func ask(
        scope: ChatScope, scopeRef: String?, question: String, dateRange: ClosedRange<Date>? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let thread = try await store.thread(for: scope, scopeRef: scopeRef)
                    let history = Array(try await store.messages(threadID: thread.id).suffix(Self.historyLimit))
                    try await store.appendChatMessage(
                        ChatMessage(threadID: thread.id, role: .user, content: question, createdAt: Date()))

                    let budget = await router.head(for: .chat)?.contextBudgetTokens ?? Self.fallbackBudgetTokens
                    let request = try await self.request(
                        scope: scope, scopeRef: scopeRef, question: question, dateRange: dateRange,
                        history: history, budgetTokens: budget)

                    var providerID: String?
                    var answer = ""
                    for try await element in router.stream(request) {
                        switch element {
                        case .provider(let id): providerID = id
                        case .delta(let delta):
                            answer += delta
                            continuation.yield(delta)
                        }
                    }
                    try Task.checkCancellation()
                    // A meeting-scoped answer may cite bare `[[ID]]` (small local models); store `[[s:ID]]`.
                    if scope == .meeting, let scopeRef {
                        let ids = Set(try await store.segments(meetingID: scopeRef).compactMap(\.id))
                        answer = Citations.normalizingBareSegmentIDs(answer, validSegmentIDs: ids)
                    }
                    let citations = try await citationsJSON(answer, scope: scope, scopeRef: scopeRef)
                    try await store.appendChatMessage(
                        ChatMessage(
                            threadID: thread.id, role: .assistant, content: answer, citationsJSON: citations,
                            provider: providerID, createdAt: Date()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    func request(
        scope: ChatScope, scopeRef: String?, question: String, dateRange: ClosedRange<Date>?,
        history: [ChatMessage], budgetTokens: Int
    ) async throws -> LLMRequest {
        var messages = history.map { LLMMessage(role: $0.role == .user ? .user : .assistant, content: $0.content) }
        let fixedChars = Self.chatSystem.count + question.count + messages.reduce(0) { $0 + $1.content.count } + 64
        let budgetChars = max(0, (budgetTokens - Self.answerReserveTokens) * 4 - fixedChars)
        let context = try await context(
            scope: scope, scopeRef: scopeRef, question: question, dateRange: dateRange, budgetChars: budgetChars)
        messages.append(.user("# Context\n\(context)\n\n# Question\n\(question)"))
        return LLMRequest(task: .chat, system: Self.chatSystem, messages: messages, maxTokens: maxAnswerTokens)
    }

    func context(
        scope: ChatScope, scopeRef: String?, question: String, dateRange: ClosedRange<Date>?, budgetChars: Int
    ) async throws -> String {
        switch scope {
        case .meeting:
            guard let meetingID = scopeRef, let meeting = try await store.meeting(id: meetingID) else {
                throw StoreError.notFound("meeting \(scopeRef ?? "nil")")
            }
            let lines = ChatTranscriptLines.lines(
                segments: try await store.segments(meetingID: meetingID),
                participants: try await store.participants(meetingID: meetingID))
            return Self.meetingContext(
                title: meeting.title, date: Self.dayString(meeting.startedAt),
                enhancedNote: try await store.enhancedNotes(meetingID: meetingID).first?.markdown,
                transcriptLines: lines, budgetChars: budgetChars)
        case .folder, .global:
            return try await searchContext(
                question: question, folderID: scope == .folder ? scopeRef : nil, dateRange: dateRange,
                budgetChars: budgetChars)
        }
    }

    /// Meeting header + newest enhanced note + as many of the newest transcript lines as fit in
    /// `budgetChars`; when older lines are dropped the transcript starts with `omittedMarker`.
    static func meetingContext(
        title: String, date: String, enhancedNote: String?, transcriptLines: [String], budgetChars: Int
    ) -> String {
        var head = "# Meeting\nTitle: \(title)\nDate: \(date)\n\n"
        if let note = enhancedNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            head += "# Enhanced notes\n\(note)\n\n"
        }
        head += "# Transcript\n"
        var remaining = budgetChars - head.count
        var kept: [String] = []
        for line in transcriptLines.reversed() {
            let cost = line.count + 1
            // Reserve room for the marker in case anything is dropped.
            let reserve = kept.count + 1 < transcriptLines.count ? omittedMarker.count + 1 : 0
            guard cost + reserve <= remaining else { break }
            kept.append(line)
            remaining -= cost
        }
        kept.reverse()
        if kept.count < transcriptLines.count { kept.insert(omittedMarker, at: 0) }
        return head + (kept.isEmpty ? "(no transcript)" : kept.joined(separator: "\n"))
    }

    /// Blocks for the best search hits (kinds segment, enhanced, raw, person): each segment hit with ±2
    /// neighbouring segments as `[[m:<meeting>#s:<id>]] <title, date> <speaker>: <text>` lines; a person hit
    /// (the question names a participant, who is the speaker rather than the text) as up to
    /// `personLineLimit` of that participant's segments in the same format; note hits as excerpts whose
    /// citations are rewritten to the cross-meeting form. Blocks are added in rank order while they fit in
    /// `budgetChars`; segments and notes appear at most once.
    func searchContext(
        question: String, folderID: String?, dateRange: ClosedRange<Date>?, budgetChars: Int
    ) async throws -> String {
        let hits = try await store.search(
            anyOf: question, kinds: [.segment, .enhanced, .raw, .person], folderID: folderID, dateRange: dateRange,
            limit: Self.searchHitLimit)
        var meetings: [String: (meeting: Meeting, lines: [ChatTranscriptLines.Line])] = [:]
        func load(_ id: String) async throws -> (meeting: Meeting, lines: [ChatTranscriptLines.Line])? {
            if let cached = meetings[id] { return cached }
            guard let meeting = try await store.meeting(id: id) else { return nil }
            let lines = ChatTranscriptLines.selected(
                segments: try await store.segments(meetingID: id),
                participants: try await store.participants(meetingID: id))
            meetings[id] = (meeting, lines)
            return (meeting, lines)
        }

        var blocks: [String] = []
        var used = 0
        var emittedSegments = Set<Int64>()
        var emittedNotes = Set<String>()
        for hit in hits {
            guard let entry = try await load(hit.meetingID) else { continue }
            let label = "\(entry.meeting.title), \(Self.dayString(entry.meeting.startedAt))"
            let block: String
            var blockSegments: [Int64] = []
            var noteKey: String?
            switch hit.kind {
            case .segment:
                guard let id = Int64(hit.refID), let index = entry.lines.firstIndex(where: { $0.id == id }) else {
                    continue
                }
                let window = entry.lines[
                    max(0, index - Self.neighbourCount)...min(entry.lines.count - 1, index + Self.neighbourCount)]
                let fresh = window.filter { !emittedSegments.contains($0.id) }
                guard !fresh.isEmpty else { continue }
                block = fresh.map { "[[m:\(hit.meetingID)#s:\($0.id)]] \(label) \($0.speaker): \($0.text)" }
                    .joined(separator: "\n")
                blockSegments = fresh.map(\.id)
            case .enhanced, .raw:
                let key = "\(hit.meetingID)|\(hit.kind.rawValue)"
                guard !emittedNotes.contains(key) else { continue }
                let text: String?
                if hit.kind == .enhanced {
                    text = try await store.enhancedNotes(meetingID: hit.meetingID).first.map {
                        Self.crossMeetingCitations($0.markdown, meetingID: hit.meetingID)
                    }
                } else {
                    text = try await store.rawNote(meetingID: hit.meetingID)?.markdown
                }
                guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let excerpt =
                    text.count > Self.noteExcerptChars ? String(text.prefix(Self.noteExcerptChars)) + "…" : text
                block = "From \(label) — \(hit.kind == .enhanced ? "enhanced notes" : "my notes"):\n\(excerpt)"
                noteKey = key
            case .person:
                guard let participantID = Int64(hit.refID) else { continue }
                let spoken = entry.lines.filter {
                    $0.participantID == participantID && !emittedSegments.contains($0.id)
                }
                .prefix(Self.personLineLimit)
                guard !spoken.isEmpty else { continue }
                block = spoken.map { "[[m:\(hit.meetingID)#s:\($0.id)]] \(label) \($0.speaker): \($0.text)" }
                    .joined(separator: "\n")
                blockSegments = spoken.map(\.id)
            case .title:
                continue
            }
            guard used + block.count + 2 <= budgetChars else { continue }
            blocks.append(block)
            used += block.count + 2
            emittedSegments.formUnion(blockSegments)
            if let noteKey { emittedNotes.insert(noteKey) }
        }
        return blocks.isEmpty ? "(no matching meeting content found)" : blocks.joined(separator: "\n\n")
    }

    /// Rewrites `[[s:ID]]` to `[[m:<meetingID>#s:ID]]`.
    static func crossMeetingCitations(_ markdown: String, meetingID: String) -> String {
        markdown.replacing(/\[\[s:(\d+)\]\]/) { "[[m:\(meetingID)#s:\($0.1)]]" }
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - Citations

    /// `citations_json` for an answer: per line with valid citations `{lineIndex, segmentIDs,
    /// meetingSegments}` (same shape as LapCatCore `Citation`). `[[s:ID]]` must name an existing segment
    /// (of the scoped meeting for `.meeting`); `[[m:M#s:ID]]` an existing segment of meeting M.
    func citationsJSON(_ answer: String, scope: ChatScope, scopeRef: String?) async throws -> String {
        let parsed = ChatCitations.parse(answer)
        let ids = Set(parsed.flatMap { $0.segmentIDs + $0.meetingSegments.map(\.segmentID) })
        let owners = Dictionary(
            try await store.segments(ids: Array(ids)).compactMap { s in s.id.map { ($0, s.meetingID) } },
            uniquingKeysWith: { a, _ in a })
        let valid: [ChatCitations.Citation] = parsed.compactMap { citation in
            var citation = citation
            citation.segmentIDs = citation.segmentIDs.filter { id in
                guard let owner = owners[id] else { return false }
                return scope != .meeting || owner == scopeRef
            }
            citation.meetingSegments = citation.meetingSegments.filter { owners[$0.segmentID] == $0.meetingID }
            return citation.segmentIDs.isEmpty && citation.meetingSegments.isEmpty ? nil : citation
        }
        let data = try JSONEncoder().encode(valid)
        return String(decoding: data, as: UTF8.self)
    }
}

// NOTE: `ChatCitations` and `ChatTranscriptLines` duplicate LapCatCore's `Citations` and
// `TranscriptFormatter` (E7, not yet on main) with the same grammar, JSON shape and line format.
// Replace them with those when E7 lands.

enum ChatCitations {
    struct MeetingSegmentRef: Codable, Hashable {
        var meetingID: String
        var segmentID: Int64
    }

    struct Citation: Codable, Hashable {
        var lineIndex: Int
        var segmentIDs: [Int64]
        var meetingSegments: [MeetingSegmentRef]
    }

    /// One entry per line that cites anything, ids in order of appearance without duplicates.
    static func parse(_ text: String) -> [Citation] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            var segments: [Int64] = []
            var refs: [MeetingSegmentRef] = []
            for match in line.matches(of: /\[\[(?:m:([^#\]\s]+)#)?s:(\d+)\]\]/) {
                guard let id = Int64(match.2) else { continue }
                if let meeting = match.1 {
                    let ref = MeetingSegmentRef(meetingID: String(meeting), segmentID: id)
                    if !refs.contains(ref) { refs.append(ref) }
                } else if !segments.contains(id) {
                    segments.append(id)
                }
            }
            return segments.isEmpty && refs.isEmpty
                ? nil : Citation(lineIndex: index, segmentIDs: segments, meetingSegments: refs)
        }
    }
}

enum ChatTranscriptLines {
    struct Line: Equatable {
        var id: Int64
        var tStartMs: Int
        var speaker: String
        var participantID: Int64?
        var text: String
    }

    /// Non-volatile, non-echo segments of the final pass if any exist (else live), by start time, with
    /// speaker = participant display name, else `Me` (mic) / `Them` (system).
    static func selected(segments: [Segment], participants: [Participant]) -> [Line] {
        let usable = segments.filter { !$0.isVolatile && !$0.isEchoDuplicate && $0.id != nil }
        let pass: SegmentPass = usable.contains { $0.pass == .final } ? .final : .live
        let names = Dictionary(
            participants.compactMap { p in p.id.map { ($0, p.displayName) } }, uniquingKeysWith: { a, _ in a })
        return usable.filter { $0.pass == pass }
            .sorted { ($0.tStartMs, $0.id ?? 0) < ($1.tStartMs, $1.id ?? 0) }
            .map { segment in
                Line(
                    id: segment.id ?? 0, tStartMs: segment.tStartMs,
                    speaker: segment.participantID.flatMap { names[$0] } ?? (segment.channel == .mic ? "Me" : "Them"),
                    participantID: segment.participantID,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    /// `[<id>] <hh:mm:ss> <speaker>: <text>` per selected segment.
    static func lines(segments: [Segment], participants: [Participant]) -> [String] {
        selected(segments: segments, participants: participants).map { line in
            let s = max(0, line.tStartMs) / 1000
            let stamp = String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
            return "[\(line.id)] \(stamp) \(line.speaker): \(line.text)"
        }
    }
}
