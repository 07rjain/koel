import Foundation

@main
struct LiveTranscriptTests {
    static func main() {
        var transcript = LiveTranscriptAccumulator()
        transcript.accept(text: "I scream", start: 0, duration: 1, isFinal: false)
        transcript.accept(text: "Ice cream", start: 0, duration: 1.2, isFinal: false)
        precondition(transcript.text == "Ice cream", "Revised hypotheses must replace earlier text")
        precondition(transcript.finalizedText.isEmpty, "Partial text must not be committed")
        transcript.accept(text: "Ice cream", start: 0, duration: 1.2, isFinal: true)
        precondition(transcript.text == "Ice cream", "Finalization must not duplicate partial text")
        transcript.accept(text: "I scream", start: 0, duration: 1, isFinal: false)
        precondition(transcript.text == "Ice cream", "Late partials must not overwrite final text")
        transcript.accept(text: " tastes great.", start: 1.2, duration: 1, isFinal: false)
        precondition(transcript.text == "Ice cream tastes great.")
        precondition(transcript.finalizedText == "Ice cream")
        transcript.accept(text: " tastes good.", start: 1.2, duration: 1, isFinal: true)
        precondition(transcript.finalizedText == "Ice cream tastes good.")

        var overlapping = LiveTranscriptAccumulator()
        overlapping.accept(text: "brown", start: 1, duration: 1, isFinal: false)
        overlapping.accept(text: " fox", start: 2, duration: 1, isFinal: false)
        overlapping.accept(text: "brown fox", start: 1, duration: 2, isFinal: true)
        precondition(overlapping.text == "brown fox", "A final range can replace several volatile segments")
        overlapping.accept(text: "broken", start: .nan, duration: 1, isFinal: true)
        precondition(overlapping.text == "brown fox", "Invalid time ranges must not corrupt the transcript")
        print("PASS: partial revisions, finalization, stable prefixes, overlap, and invalid time ranges")
    }
}
