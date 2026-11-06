import AVFoundation
import Foundation
import Speech
import os

/// AVAudioFormat is immutable. The wrapper lets the same format description
/// cross Swift concurrency boundaries without sharing mutable audio buffers.
struct SpeechAudioFormat: @unchecked Sendable {
    let value: AVAudioFormat
}

/// Owned, immutable-after-enqueue microphone data. AnalyzerInput cannot wrap
/// arbitrary hardware formats (including stereo), so wrap only after conversion.
private struct SpeechAudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Used by exactly one AsyncSequence consumer, off the microphone callback.
/// AVAudioConverter retains resampling state between consecutive chunks.
private final class SpeechPCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter

    init(from source: AVAudioFormat, to destination: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: source, to: destination) else {
            throw AppError("Cannot convert microphone audio for Apple Speech.")
        }
        self.converter = converter
    }

    func convert(_ input: SpeechAudioChunk) throws -> AnalyzerInput {
        let source = input.buffer
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw AppError("Cannot allocate an Apple Speech audio buffer.")
        }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            let alreadySupplied = supplied.withLock { supplied in
                let previous = supplied
                supplied = true
                return previous
            }
            if alreadySupplied { state.pointee = .noDataNow; return nil }
            state.pointee = .haveData
            return input.buffer
        }
        guard status != .error else { throw error ?? AppError("Microphone audio conversion failed.") as NSError }
        return AnalyzerInput(buffer: output)
    }
}

/// One live utterance. The input stream owns every queued buffer, and a single
/// analysis task converts/consumes it while a second task collects live results.
final class AppleSpeechLiveSession: Sendable {
    private let input: AsyncThrowingStream<SpeechAudioChunk, Error>.Continuation
    private let analyzer: SpeechAnalyzer
    private let analysis: Task<Void, Error>
    private let results: Task<Transcript, Error>

    init(transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer,
         sourceFormat: SpeechAudioFormat, analysisFormat: SpeechAudioFormat, locale: String,
         onUpdate: @escaping @Sendable (LiveSpeechUpdate) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        let stream = AsyncThrowingStream<SpeechAudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        input = stream.continuation
        self.analyzer = analyzer
        let continuation = stream.continuation
        let converter = try SpeechPCMConverter(from: sourceFormat.value, to: analysisFormat.value)
        let started = Date()
        let results = Task {
            do {
                var transcript = LiveTranscriptAccumulator()
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    transcript.accept(text: String(result.text.characters),
                                      start: result.range.start.seconds,
                                      duration: result.range.duration.seconds, isFinal: result.isFinal)
                    onUpdate(LiveSpeechUpdate(text: transcript.text, isFinal: result.isFinal))
                }
                try Task.checkCancellation()
                return Transcript(text: transcript.finalizedText, provider: "apple",
                                  model: "Apple Speech Live · \(locale)",
                                  elapsedMs: Date().timeIntervalSince(started) * 1000)
            } catch {
                continuation.finish(throwing: error)
                await analyzer.cancelAndFinishNow()
                if !Task.isCancelled { onFailure(error.localizedDescription) }
                throw error
            }
        }
        self.results = results
        analysis = Task {
            do {
                let converted = stream.stream.compactMap { packet -> AnalyzerInput? in
                    let converted = try converter.convert(packet)
                    return converted.buffer.frameLength > 0 ? converted : nil
                }
                if let end = try await analyzer.analyzeSequence(converted) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                if !Task.isCancelled { onFailure(error.localizedDescription) }
                throw error
            }
        }
    }

    /// Ownership of this buffer transfers to the stream; never reuse/mutate it.
    func append(_ buffer: AVAudioPCMBuffer) {
        if case .dropped = input.yield(SpeechAudioChunk(buffer: buffer)) {
            input.finish(throwing: AppError("Apple Speech cannot keep up with the microphone. Try a shorter recording."))
        }
    }

    func fail(_ message: String) { input.finish(throwing: AppError(message)) }

    func finish() async throws -> Transcript {
        input.finish()
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            analysis.cancel()
            results.cancel()
            await analyzer.cancelAndFinishNow()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await analysis.value
            return try await results.value
        } onCancel: {
            analysis.cancel()
            results.cancel()
            Task { await self.analyzer.cancelAndFinishNow() }
        }
    }

    func cancel() async {
        input.finish()
        analysis.cancel()
        results.cancel()
        await analyzer.cancelAndFinishNow()
        _ = try? await analysis.value
        _ = try? await results.value
    }
}
