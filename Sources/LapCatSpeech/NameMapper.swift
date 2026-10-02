import Foundation
import LapCatCore

/// Who a final-pass segment is attributed to.
public struct SegmentAssignment: Sendable, Hashable {
    public enum Basis: Sendable, Hashable {
        /// Mic channel: always the user (`is_me` participant).
        case me
        /// Platform speaker events cover ≥ 40 % of the segment.
        case speakerEvents
        /// The name that won most directly-named segments of the same diarization cluster.
        case clusterVote
        /// No name evidence: the `Speaker N` cluster participant (`source='cluster'`).
        case cluster
        /// System segment that no diarized turn overlaps: left unassigned.
        case unassigned
    }

    public var segmentID: Int64
    /// Participant display name to assign; nil only for `.unassigned`.
    public var participantName: String?
    /// Diarization cluster (`Speaker N`) with the largest overlap, written to `segment.cluster_label`.
    public var cluster: String?
    public var basis: Basis

    public init(segmentID: Int64, participantName: String?, cluster: String?, basis: Basis) {
        self.segmentID = segmentID
        self.participantName = participantName
        self.cluster = cluster
        self.basis = basis
    }
}

/// Combines diarization turns with platform speaker events to name final-pass segments.
public enum NameMapper {
    /// Share of a segment's span that one name's speaker events must cover to name it directly.
    public static let directCoverage = 0.4

    /// - Parameters:
    ///   - segments: the meeting's segments; only non-volatile final-pass segments with ids are assigned.
    ///   - turns: system-channel diarization.
    ///   - events: platform speaker events (an open event, `tEndMs == nil`, extends indefinitely).
    ///   - meName: display name of the meeting's `is_me` participant (`userDisplayName`).
    /// - Returns: one assignment per assigned segment, in input order.
    public static func assign(
        segments: [Segment], turns: [DiarizedTurn], events: [SpeakerEvent], meName: String
    ) -> [SegmentAssignment] {
        struct Pending {
            var id: Int64
            var cluster: String?
            var directName: String?
        }

        var pending: [Pending] = []
        var micIDs = Set<Int64>()
        for segment in segments where segment.pass == .final && !segment.isVolatile {
            guard let id = segment.id else { continue }
            switch segment.channel {
            case .mic:
                micIDs.insert(id)
                pending.append(Pending(id: id))
            case .system:
                pending.append(Pending(
                    id: id,
                    cluster: dominantCluster(segment, turns: turns),
                    directName: directName(segment, events: events)
                ))
            }
        }

        // Cluster-level vote over the directly named segments of each cluster.
        var votes: [String: [String: Int]] = [:]
        for item in pending {
            if let cluster = item.cluster, let name = item.directName { votes[cluster, default: [:]][name, default: 0] += 1 }
        }
        let clusterNames = votes.compactMapValues { tally in
            tally.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }

        return pending.map { item in
            if micIDs.contains(item.id) {
                return SegmentAssignment(segmentID: item.id, participantName: meName, cluster: nil, basis: .me)
            }
            if let name = item.directName {
                return SegmentAssignment(segmentID: item.id, participantName: name, cluster: item.cluster, basis: .speakerEvents)
            }
            guard let cluster = item.cluster else {
                return SegmentAssignment(segmentID: item.id, participantName: nil, cluster: nil, basis: .unassigned)
            }
            if let name = clusterNames[cluster] {
                return SegmentAssignment(segmentID: item.id, participantName: name, cluster: cluster, basis: .clusterVote)
            }
            return SegmentAssignment(segmentID: item.id, participantName: cluster, cluster: cluster, basis: .cluster)
        }
    }

    /// Turn with the maximal overlap (≥ 1 ms); ties go to the earlier turn.
    static func dominantCluster(_ segment: Segment, turns: [DiarizedTurn]) -> String? {
        var best: (overlap: Int, cluster: String)?
        for turn in turns {
            let shared = overlap(segment.tStartMs, segment.tEndMs, turn.startMs, turn.endMs)
            if shared > 0, shared > (best?.overlap ?? 0) { best = (shared, turn.cluster) }
        }
        return best?.cluster
    }

    /// The name whose summed event overlap is largest, when it covers ≥ 40 % of the segment.
    /// Ties go to the alphabetically first name.
    static func directName(_ segment: Segment, events: [SpeakerEvent]) -> String? {
        var totals: [String: Int] = [:]
        for event in events {
            let shared = overlap(segment.tStartMs, segment.tEndMs, event.tStartMs, event.tEndMs ?? Int.max)
            if shared > 0 { totals[event.displayName, default: 0] += shared }
        }
        guard let best = totals.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        let span = max(1, segment.tEndMs - segment.tStartMs)
        return Double(best.value) >= directCoverage * Double(span) ? best.key : nil
    }

    static func overlap(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Int {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }
}
