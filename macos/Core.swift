import Foundation

struct AppError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Config: Codable, Sendable {
    var provider: String
    var localModel: String
    var appleLocale: String
    var language: String?
    var groqModel: String
    var pasteAfterTranscription: Bool

    enum CodingKeys: String, CodingKey {
        case provider, language
        case localModel = "local_model", appleLocale = "apple_locale"
        case groqModel = "groq_model", pasteAfterTranscription = "paste_after_transcription"
    }
}

struct LocalModel: Codable, Sendable {
    let id: String
    let name: String
    let bytes: Int64
    let installed: Bool
    let languages: String
}

struct CoreStatus: Codable, Sendable {
    var config: Config
    let models: [LocalModel]
    let dataDir: String
    let version: String
    let repository: String
    enum CodingKeys: String, CodingKey { case config, models, version, repository; case dataDir = "data_dir" }
}

struct VersionInfo: Decodable, Sendable {
    let version: String
    let repository: String
}

struct UpdateInfo: Codable, Sendable {
    enum Status: String, Codable, Sendable { case available; case upToDate = "up_to_date"; case noReleases = "no_releases" }
    let status: Status
    let currentVersion: String
    let latestVersion: String?
    let releaseURL: URL
    let downloadURL: URL?
    enum CodingKeys: String, CodingKey {
        case status
        case currentVersion = "current_version", latestVersion = "latest_version"
        case releaseURL = "release_url", downloadURL = "download_url"
    }
}

struct Transcript: Codable, Sendable {
    let text: String
    let provider: String
    let model: String
    let elapsedMs: Double
    enum CodingKeys: String, CodingKey { case text, provider, model; case elapsedMs = "elapsed_ms" }
}

enum Core {
    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: String?
    }

    /// All calls that can perform inference, disk I/O, or HTTP run off the UI thread.
    static func call<T: Decodable & Sendable>(_ request: [String: Any], as type: T.Type) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: data, as: UTF8.self)
        return try await Task.detached(priority: .userInitiated) {
            let response: String = try json.withCString { pointer in
                guard let result = lw_call(pointer) else { throw AppError("The Rust engine returned no response.") }
                defer { lw_free(result) }
                return String(cString: result)
            }
            let envelope = try JSONDecoder().decode(Envelope<T>.self, from: Data(response.utf8))
            guard envelope.ok, let value = envelope.data else {
                throw AppError(envelope.error ?? "The Rust engine could not complete the request.")
            }
            return value
        }.value
    }

    static func status() async throws -> CoreStatus {
        try await call(["op": "status"], as: CoreStatus.self)
    }

    static func version() async throws -> VersionInfo {
        try await call(["op": "version"], as: VersionInfo.self)
    }

    static func checkForUpdates() async throws -> UpdateInfo {
        try await call(["op": "check_update"], as: UpdateInfo.self)
    }

    static func save(_ config: Config) async throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        let _: Config = try await call(["op": "configure", "config": object], as: Config.self)
    }

    static func download(_ id: String) async throws {
        struct Download: Decodable, Sendable { let installed: Bool }
        let _: Download = try await call(["op": "download", "model": id], as: Download.self)
    }

    static func transcribe(_ url: URL, key: String?) async throws -> Transcript {
        var request: [String: Any] = ["op": "transcribe", "path": url.path]
        if let key { request["api_key"] = key }
        return try await call(request, as: Transcript.self)
    }
}
