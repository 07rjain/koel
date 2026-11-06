import Foundation

/// Volatile hypotheses replace overlapping hypotheses; they are not appended
/// to the committed transcript. Final segments remain stable across updates.
struct LiveTranscriptAccumulator {
    private struct Segment {
        let start: Double
        let end: Double
        let text: String
        let isFinal: Bool

        func overlaps(start: Double, end: Double) -> Bool {
            self.start == start || (self.start < end && start < self.end)
        }
    }

    private var segments: [Segment] = []
    var text: String { joined(segments) }
    var finalizedText: String { joined(segments.filter(\.isFinal)) }

    mutating func accept(text: String, start: Double, duration: Double, isFinal: Bool) {
        let end = start + duration
        guard start.isFinite, end.isFinite, duration >= 0 else { return }
        if !isFinal && segments.contains(where: { $0.isFinal && $0.overlaps(start: start, end: end) }) {
            return // Ignore a late hypothesis for audio that is already final.
        }
        segments.removeAll { $0.overlaps(start: start, end: end) && (isFinal || !$0.isFinal) }
        segments.append(Segment(start: start, end: end, text: text, isFinal: isFinal))
    }

    private func joined(_ segments: [Segment]) -> String {
        segments.sorted { $0.start < $1.start }.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct LiveSpeechUpdate: Codable, Sendable {
    let text: String
    let isFinal: Bool
    enum CodingKeys: String, CodingKey { case text; case isFinal = "is_final" }
}
