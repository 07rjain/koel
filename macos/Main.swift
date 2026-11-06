import AppKit
import Foundation

@main
struct LocalWhisperApp {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            Task { @MainActor in
                do {
                    let engine = AppleSpeechEngine()
                    switch arguments.first {
                    case "--version", "-V":
                        let info = try await Core.version()
                        print("Local Whisper \(info.version)")
                    case "--check-updates":
                        let result = try await Core.checkForUpdates()
                        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
                    case "--diagnose":
                        let status = try await Core.status()
                        print(String(decoding: try JSONEncoder().encode(status), as: UTF8.self))
                        print(await engine.availability(locale: status.config.appleLocale))
                    case "--prepare-apple":
                        let locale = arguments.count > 1 ? arguments[1] : "en-US"
                        try await engine.prepare(locale: locale)
                        print(await engine.availability(locale: locale))
                    case "--apple-transcribe" where arguments.count > 1:
                        let url = URL(fileURLWithPath: arguments[1])
                        let locale = arguments.count > 2 ? arguments[2] : "en-US"
                        let transcript = try await engine.transcribe(url: url, locale: locale)
                        print(String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self))
                    case "--apple-stream-file" where arguments.count > 1:
                        let url = URL(fileURLWithPath: arguments[1])
                        let locale = arguments.count > 2 ? arguments[2] : "en-US"
                        let transcript = try await engine.streamFile(url: url, locale: locale,
                            verifyCancellation: arguments.contains("--verify-cancellation"),
                            onUpdate: { StreamingDiagnosticEvent(event: "update", text: $0.text, isFinal: $0.isFinal).printJSON() },
                            onInputFinished: { StreamingDiagnosticEvent(event: "input_finished").printJSON() })
                        StreamingDiagnosticEvent(event: "final", transcript: transcript).printJSON()
                    case "--transcribe" where arguments.count > 1:
                        let status = try await Core.status()
                        let url = URL(fileURLWithPath: arguments[1])
                        let transcript: Transcript
                        if status.config.provider == "apple" {
                            transcript = try await engine.transcribe(url: url, locale: status.config.appleLocale)
                        } else {
                            transcript = try await Core.transcribe(url, key: status.config.provider == "groq" ? GroqKeychain.read() : nil)
                        }
                        print(String(decoding: try JSONEncoder().encode(transcript), as: UTF8.self))
                    default:
                        throw AppError("Use --version, --check-updates, --diagnose, --prepare-apple [locale], --apple-transcribe FILE.wav [locale], --apple-stream-file FILE.wav [locale], or --transcribe FILE.wav.")
                    }
                    lw_shutdown()
                    exit(0)
                } catch {
                    lw_shutdown()
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(1)
                }
            }
            RunLoop.main.run()
        } else {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
