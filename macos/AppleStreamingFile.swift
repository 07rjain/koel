import AVFoundation
import Foundation

extension AppleSpeechEngine {
    /// Exercise the microphone's streaming pipeline with synthetic/file audio,
    /// paced at its sample rate. No microphone or cloud provider is accessed.
    func streamFile(url: URL, locale: String, verifyCancellation: Bool = false,
                    onUpdate: @escaping @Sendable (LiveSpeechUpdate) -> Void,
                    onInputFinished: @escaping @Sendable () -> Void) async throws -> Transcript {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration >= 0.1 && duration <= 300 else {
            throw AppError("Choose audio between 0.1 seconds and five minutes long.")
        }
        if verifyCancellation {
            // Discard a live session, then start another with the same engine.
            // This exercises the same teardown used by Discard Recording.
            let discarded = try await startLive(locale: locale, sourceFormat: SpeechAudioFormat(value: format),
                                                 onUpdate: { _ in }, onFailure: { _ in })
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) {
                try file.read(into: buffer, frameCount: 2048)
                discarded.append(buffer)
            }
            await discarded.cancel()
            file.framePosition = 0
        }
        let session = try await startLive(locale: locale, sourceFormat: SpeechAudioFormat(value: format),
                                          onUpdate: onUpdate, onFailure: { _ in })
        do {
            while file.framePosition < file.length {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else {
                    throw AppError("Cannot allocate a streaming test buffer.")
                }
                try file.read(into: buffer, frameCount: 2048)
                let seconds = Double(buffer.frameLength) / format.sampleRate
                session.append(buffer)
                try await Task.sleep(for: .seconds(seconds))
            }
            onInputFinished()
            return try await session.finish()
        } catch {
            await session.cancel()
            throw error
        }
    }
}

struct StreamingDiagnosticEvent: Encodable, Sendable {
    let event: String
    var text: String? = nil
    var isFinal: Bool? = nil
    var transcript: Transcript? = nil
    enum CodingKeys: String, CodingKey { case event, text, transcript; case isFinal = "is_final" }

    func printJSON() {
        if let data = try? JSONEncoder().encode(self) { print(String(decoding: data, as: UTF8.self)) }
    }
}
