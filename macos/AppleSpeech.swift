import AVFoundation
import Foundation
import Speech

/// SpeechAnalyzer runs locally. Missing assets require an explicit Prepare action;
/// dictation never silently falls back to a cloud recognizer or another provider.
actor AppleSpeechEngine {
    private var reservedLocale: Locale?

    func availability(locale identifier: String) async -> String {
        guard SpeechTranscriber.isAvailable else { return "Apple Speech is unavailable on this Mac" }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            return "Apple Speech does not support \(identifier)"
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed: return "Apple Speech ready · on device"
        case .downloading: return "Apple is downloading speech assets"
        case .supported: return "Prepare Apple Speech to download language assets"
        default: return "Apple Speech is unavailable for \(identifier)"
        }
    }

    private func makeTranscriber(identifier: String, allowDownload: Bool, live: Bool = false) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw AppError("Apple Speech is unavailable on this Mac.") }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw AppError("Apple Speech does not support \(identifier). Choose another language.")
        }
        if reservedLocale != locale {
            if let previous = reservedLocale { await AssetInventory.release(reservedLocale: previous) }
            reservedLocale = nil
            try await AssetInventory.reserve(locale: locale)
            reservedLocale = locale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: live ? .progressiveTranscription : .transcription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard allowDownload else {
                throw AppError("Apple's speech assets are missing. Choose Prepare Apple Speech from the menu while online.")
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw AppError("Apple could not install the speech assets. Check your connection and try again.")
        }
        return transcriber
    }

    func prepare(locale: String) async throws {
        _ = try await makeTranscriber(identifier: locale, allowDownload: true)
    }

    func startLive(locale: String, sourceFormat: SpeechAudioFormat,
                   onUpdate: @escaping @Sendable (LiveSpeechUpdate) -> Void,
                   onFailure: @escaping @Sendable (String) -> Void) async throws -> AppleSpeechLiveSession {
        let transcriber = try await makeTranscriber(identifier: locale, allowDownload: false, live: true)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: sourceFormat.value) else {
            throw AppError("Apple Speech did not provide a compatible audio format.")
        }
        try await analyzer.prepareToAnalyze(in: format)
        return try AppleSpeechLiveSession(transcriber: transcriber, analyzer: analyzer,
                                          sourceFormat: sourceFormat, analysisFormat: SpeechAudioFormat(value: format),
                                          locale: locale, onUpdate: onUpdate, onFailure: onFailure)
    }

    func transcribe(url: URL, locale: String) async throws -> Transcript {
        let start = Date()
        let transcriber = try await makeTranscriber(identifier: locale, allowDownload: false)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(120))
            await analyzer.cancelAndFinishNow()
            collector.cancel()
        }
        defer { timeout.cancel() }
        let text: String = try await withTaskCancellationHandler {
            do {
                let audio = try AVAudioFile(forReading: url)
                let duration = Double(audio.length) / audio.processingFormat.sampleRate
                guard duration >= 0.1 && duration <= 300 else {
                    throw AppError("Choose audio between 0.1 seconds and five minutes long.")
                }
                if let end = try await analyzer.analyzeSequence(from: audio) {
                    try await analyzer.finalizeAndFinish(through: end)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                return try await collector.value
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        try Task.checkCancellation()
        guard Date().timeIntervalSince(start) < 120 else { throw AppError("Apple Speech timed out. Try a shorter recording.") }
        return Transcript(text: text, provider: "apple", model: "Apple Speech · \(locale)",
                          elapsedMs: Date().timeIntervalSince(start) * 1000)
    }
}
