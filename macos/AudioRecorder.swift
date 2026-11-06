import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private(set) var url: URL?
    var onLimitReached: (() -> Void)?

    func start(shouldStart: @MainActor () -> Bool = { true }) async throws {
        try await Self.requirePermission()
        guard shouldStart() else { throw CancellationError() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalWhisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("recording.wav")
        self.url = url
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record(forDuration: 300) else {
                throw AppError("Cannot start microphone recording. Check that an input device is connected.")
            }
            self.recorder = recorder
        } catch {
            cleanUp()
            throw error
        }
    }

    static func requirePermission() async throws {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted: Bool
        if permission == .authorized { granted = true }
        else if permission == .notDetermined { granted = await AVCaptureDevice.requestAccess(for: .audio) }
        else { granted = false }
        guard granted else { throw AppError("Microphone access is off. Enable Local Whisper in System Settings → Privacy & Security → Microphone.") }
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        return url
    }

    func cleanUp() {
        recorder?.stop()
        recorder = nil
        if let url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        url = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onLimitReached?() }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in self?.onLimitReached?() }
    }
}
