import Foundation

/// LLM suggestions for which candidate name each unnamed `Speaker N` cluster is (FR-4.4).
/// Suggestions are never applied automatically; the app stores them as `llm_suggested` participants.
public enum SpeakerSuggester {
    public struct Suggestion: Sendable, Hashable, Decodable {
        public var cluster: String
        public var name: String
        public var evidenceSegmentID: Int64?

        public init(cluster: String, name: String, evidenceSegmentID: Int64?) {
            self.cluster = cluster
            self.name = name
            self.evidenceSegmentID = evidenceSegmentID
        }

        enum CodingKeys: String, CodingKey {
            case cluster, name
            case evidenceSegmentID = "evidence_segment_id"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cluster = try container.decode(String.self, forKey: .cluster)
            name = try container.decode(String.self, forKey: .name)
            // Models sometimes quote the id; accept both, and tolerate it missing.
            if let id = try? container.decodeIfPresent(Int64.self, forKey: .evidenceSegmentID) {
                evidenceSegmentID = id
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .evidenceSegmentID) {
                evidenceSegmentID = Int64(text)
            } else {
                evidenceSegmentID = nil
            }
        }
    }

    struct Reply: Decodable, Sendable {
        var suggestions: [Suggestion]
    }

    public static let system = """
    Given a transcript where some speakers are labeled Speaker N, and a list of candidate names, suggest which candidate each Speaker N most likely is, based only on how people address each other. Reply with only {"suggestions":[{"cluster":"Speaker 1","name":"…","evidence_segment_id":123}]}; omit clusters you cannot support.
    """

    /// - Parameters:
    ///   - transcript: `TranscriptFormatter.forLLM` output (segment ids in brackets).
    ///   - clusters: the unnamed cluster labels (`Speaker 1`, …).
    ///   - candidates: calendar attendees and platform names not yet assigned.
    /// - Returns: at most one suggestion per requested cluster, each naming a candidate (spelled as
    ///   given in `candidates`), without suggesting one candidate for two clusters. Empty when there is
    ///   nothing to ask.
    public static func suggest(
        router: LLMRouter, transcript: String, clusters: [String], candidates: [String]
    ) async throws -> [Suggestion] {
        guard !clusters.isEmpty, !candidates.isEmpty else { return [] }
        let user = """
        Unlabeled speakers: \(clusters.joined(separator: ", "))
        Candidate names: \(candidates.joined(separator: ", "))

        # Transcript
        \(transcript)
        """
        let request = LLMRequest(task: .classify, system: system, messages: [.user(user)], maxTokens: 1024, expectJSON: true)
        let reply = try await router.completeJSON(request, as: Reply.self).value
        return validated(reply.suggestions, clusters: clusters, candidates: candidates)
    }

    /// Keeps suggestions for requested clusters naming a known candidate (case-insensitive, canonical
    /// spelling restored); the first suggestion wins per cluster and per candidate.
    static func validated(_ suggestions: [Suggestion], clusters: [String], candidates: [String]) -> [Suggestion] {
        let wantedClusters = Set(clusters)
        var canonical: [String: String] = [:]
        for candidate in candidates {
            let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if canonical[key] == nil { canonical[key] = candidate }
        }
        var usedClusters = Set<String>()
        var usedNames = Set<String>()
        var result: [Suggestion] = []
        for var suggestion in suggestions {
            let cluster = suggestion.cluster.trimmingCharacters(in: .whitespacesAndNewlines)
            guard wantedClusters.contains(cluster),
                  let name = canonical[suggestion.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
                  !usedClusters.contains(cluster), !usedNames.contains(name)
            else { continue }
            usedClusters.insert(cluster)
            usedNames.insert(name)
            suggestion.cluster = cluster
            suggestion.name = name
            result.append(suggestion)
        }
        return result
    }
}
