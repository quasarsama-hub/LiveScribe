import Foundation

enum AppConstants {
    /// Bundle ID the project is built with. AltStore/SideStore append your team ID when re-signing.
    static let baseBundleID = "dev.livescribe.app"
    /// App group shared by the app and the broadcast extension (AltStore rewrites this too).
    static let baseAppGroup = "group.dev.livescribe.app"
}

enum TranscriptLanguage: String, Codable, CaseIterable, Identifiable {
    case korean = "ko-KR"
    case english = "en-US"

    var id: String { rawValue }
    var label: String { self == .korean ? "한국어" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
}

enum CaptureSource: String, Codable {
    case system
    case microphone

    var label: String { self == .system ? "System audio" : "Microphone" }
}

struct TranscriptSession: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var source: CaptureSource
    var language: TranscriptLanguage
    var text: String
}

/// Written by the broadcast extension a few times per second, read by the app.
struct LiveState: Codable, Equatable {
    var sessionID: UUID
    var isActive: Bool
    var committedTail: String
    var volatile: String
    var status: String
    var heartbeat: Date
    var language: TranscriptLanguage
    var level: Float
    var lastAudio: Date?
}

/// Written by the app, polled by the broadcast extension.
struct ControlState: Codable, Equatable {
    var language: TranscriptLanguage = .korean
    var preferOnDevice: Bool = true
    var stopRequestedFor: UUID? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = (try? c.decodeIfPresent(TranscriptLanguage.self, forKey: .language)) ?? .korean
        preferOnDevice = (try? c.decodeIfPresent(Bool.self, forKey: .preferOnDevice)) ?? true
        stopRequestedFor = try? c.decodeIfPresent(UUID.self, forKey: .stopRequestedFor)
    }
}
