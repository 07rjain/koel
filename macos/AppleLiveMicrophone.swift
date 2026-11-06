import AVFoundation
import Foundation

/// Apple dictation streams owned chunks straight from the audio engine; it
/// does not write a WAV file or wait for Stop to begin recognition.
@MainActor
final class AppleLiveMicrophone {
    private var engine: AVAudioEngine?

    func start(speech: AppleSpeechEngine, locale: String,
               shouldStart: @MainActor () -> Bool = { true },
               onUpdate: @escaping @Sendable (LiveSpeechUpdate) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws -> AppleSpeechLiveSession {
        try await AudioRecorder.requirePermission()
        guard shouldStart() else { throw CancellationError() }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            throw AppError("No microphone input is available.")
        }
        let session = try await speech.startLive(locale: locale, sourceFormat: SpeechAudioFormat(value: format),
                                                onUpdate: onUpdate, onFailure: onFailure)
        guard shouldStart() else { await session.cancel(); throw CancellationError() }
        // Explicitly Sendable: this callback runs on the audio thread, not the
        // main actor. Copy the system-owned buffer before returning it to Core Audio.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            guard let owned = Self.copy(buffer) else {
                session.fail("Cannot copy microphone audio for Apple Speech.")
                return
            }
            session.append(owned)
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: format, block: tap)
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
            return session
        } catch {
            node.removeTap(onBus: 0)
            engine.stop()
            await session.cancel()
            throw error
        }
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    nonisolated private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        destination.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard input.count == output.count else { return nil }
        for index in input.indices {
            guard input[index].mDataByteSize <= output[index].mDataByteSize else { return nil }
            guard let src = input[index].mData, let dst = output[index].mData else { return nil }
            memcpy(dst, src, Int(input[index].mDataByteSize))
        }
        return destination
    }
}
