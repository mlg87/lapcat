import Foundation

/// A segment of another meeting, cited as `[[m:MEETING_ID#s:ID]]`.
public struct MeetingSegmentRef: Codable, Sendable, Hashable {
    public var meetingID: String
    public var segmentID: Int64

    public init(meetingID: String, segmentID: Int64) {
        self.meetingID = meetingID
        self.segmentID = segmentID
    }
}

/// One citation marker: `[[s:ID]]` (same meeting) or `[[m:MEETING_ID#s:ID]]` (cross-meeting).
public enum CitationRef: Sendable, Hashable {
    case segment(Int64)
    case meetingSegment(MeetingSegmentRef)
}

/// The citations on one line of LLM-written Markdown; persisted as `citations_json`.
public struct Citation: Codable, Sendable, Hashable {
    /// Zero-based line index in the Markdown split on `\n`.
    public var lineIndex: Int
    public var segmentIDs: [Int64]
    public var meetingSegments: [MeetingSegmentRef]

    public init(lineIndex: Int, segmentIDs: [Int64], meetingSegments: [MeetingSegmentRef] = []) {
        self.lineIndex = lineIndex
        self.segmentIDs = segmentIDs
        self.meetingSegments = meetingSegments
    }
}

/// The shared parser for the citation grammar used by enhanced notes, chat and export.
public enum Citations {
    // Group 1: same-meeting segment id; groups 2+3: meeting id and segment id.
    private static let pattern = try! NSRegularExpression(
        pattern: #"\[\[(?:s:(\d+)|m:([^#\]\s]+)#s:(\d+))\]\]"#)

    /// Citations per line, in line order. Lines without a valid citation are omitted.
    /// - Parameter validSegmentIDs: when set, `[[s:ID]]` markers whose id is not in the set are dropped
    ///   (the model invented or mistyped it). Cross-meeting markers are not checked against it.
    public static func parse(_ markdown: String, validSegmentIDs: Set<Int64>? = nil) -> [Citation] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            var segmentIDs: [Int64] = []
            var meetingSegments: [MeetingSegmentRef] = []
            for ref in references(in: String(line)) {
                switch ref {
                case .segment(let id):
                    if validSegmentIDs?.contains(id) ?? true, !segmentIDs.contains(id) { segmentIDs.append(id) }
                case .meetingSegment(let ref):
                    if !meetingSegments.contains(ref) { meetingSegments.append(ref) }
                }
            }
            if segmentIDs.isEmpty, meetingSegments.isEmpty { return nil }
            return Citation(lineIndex: index, segmentIDs: segmentIDs, meetingSegments: meetingSegments)
        }
    }

    private static let barePattern = try! NSRegularExpression(pattern: #"\[\[(\d+)\]\]"#)

    /// Rewrites bare `[[ID]]` markers to `[[s:ID]]` when `ID` is one of `validSegmentIDs`.
    ///
    /// Small local models keep the transcript's `[ID]` line prefix and drop the `s:`; without this
    /// their notes would carry no usable citations. Unknown bare numbers are left untouched.
    public static func normalizingBareSegmentIDs(_ markdown: String, validSegmentIDs: Set<Int64>) -> String {
        let text = markdown as NSString
        var result = ""
        var cursor = 0
        for match in barePattern.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            let idRange = match.range(at: 1)
            guard let id = Int64(text.substring(with: idRange)), validSegmentIDs.contains(id) else { continue }
            result += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "[[s:\(id)]]"
            cursor = match.range.location + match.range.length
        }
        result += text.substring(from: cursor)
        return result
    }

    /// Every well-formed marker in `text`, in order of appearance. Ids that overflow `Int64` are skipped.
    public static func references(in text: String) -> [CitationRef] {
        matches(in: text).compactMap(\.ref)
    }

    /// Replaces each well-formed marker with `transform(ref)`; malformed ones are left as written.
    public static func replacing(in markdown: String, _ transform: (CitationRef) -> String) -> String {
        var result = ""
        var cursor = markdown.startIndex
        for match in matches(in: markdown) {
            guard let ref = match.ref else { continue }
            result += markdown[cursor..<match.range.lowerBound]
            result += transform(ref)
            cursor = match.range.upperBound
        }
        result += markdown[cursor...]
        return result
    }

    /// Markers turned into Markdown links: `[⌃ID](lapcat://segment/ID)` and
    /// `[⌃ID](lapcat://meeting/MEETING_ID/segment/ID)`.
    public static func linkified(_ markdown: String) -> String {
        replacing(in: markdown) { "[⌃\($0.segmentID)](\(url(for: $0).absoluteString))" }
    }

    /// The `lapcat://` URL a citation links to.
    public static func url(for ref: CitationRef) -> URL {
        switch ref {
        case .segment(let id):
            return URL(string: "lapcat://segment/\(id)")!
        case .meetingSegment(let ref):
            let meeting =
                ref.meetingID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
                ?? ref.meetingID
            return URL(string: "lapcat://meeting/\(meeting)/segment/\(ref.segmentID)")!
        }
    }

    /// The citation a `lapcat://` link points at (inverse of `url(for:)`), or nil for any other URL.
    public static func target(of url: URL) -> CitationRef? {
        guard url.scheme == "lapcat", let host = url.host() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "segment":
            guard parts.count == 1, let id = Int64(parts[0]) else { return nil }
            return .segment(id)
        case "meeting":
            guard parts.count == 3, parts[1] == "segment", let id = Int64(parts[2]) else { return nil }
            return .meetingSegment(MeetingSegmentRef(meetingID: parts[0], segmentID: id))
        default:
            return nil
        }
    }

    /// `citations_json` column value.
    public static func json(_ citations: [Citation]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(citations) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct Match {
        var range: Range<String.Index>
        var ref: CitationRef?
    }

    private static func matches(in text: String) -> [Match] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            func group(_ index: Int) -> String? {
                Range(result.range(at: index), in: text).map { String(text[$0]) }
            }
            let ref: CitationRef?
            if let id = group(1) {
                ref = Int64(id).map(CitationRef.segment)
            } else if let meetingID = group(2), let id = group(3).flatMap({ Int64($0) }) {
                ref = .meetingSegment(MeetingSegmentRef(meetingID: meetingID, segmentID: id))
            } else {
                ref = nil
            }
            return Match(range: range, ref: ref)
        }
    }
}

extension CitationRef {
    public var segmentID: Int64 {
        switch self {
        case .segment(let id): id
        case .meetingSegment(let ref): ref.segmentID
        }
    }
}
