import Foundation

/// File-based storage in the app group container, shared by the app and the broadcast extension.
enum SharedStore {
    static let groupIdentifier: String? = resolveAppGroup()

    static let rootURL: URL = {
        let fm = FileManager.default
        if let group = groupIdentifier,
           let url = fm.containerURL(forSecurityApplicationGroupIdentifier: group) {
            let root = url.appendingPathComponent("LiveScribe", isDirectory: true)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        // Not shared: the app and the extension each get their own folder.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("LiveScribe", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    static var isShared: Bool { groupIdentifier != nil }

    static var sessionsURL: URL { rootURL.appendingPathComponent("Sessions", isDirectory: true) }
    static var liveURL: URL { rootURL.appendingPathComponent("live.json") }
    static var controlURL: URL { rootURL.appendingPathComponent("control.json") }

    // MARK: Sessions

    static func loadSessions() -> [TranscriptSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TranscriptSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func loadSession(id: UUID) -> TranscriptSession? {
        let url = sessionsURL.appendingPathComponent("\(id.uuidString).json")
        return try? JSONDecoder().decode(TranscriptSession.self, from: Data(contentsOf: url))
    }

    static func save(_ session: TranscriptSession) {
        let fm = FileManager.default
        try? fm.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let url = sessionsURL.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func delete(id: UUID) {
        let url = sessionsURL.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Live state & control

    static func loadLive() -> LiveState? {
        guard let data = try? Data(contentsOf: liveURL) else { return nil }
        return try? JSONDecoder().decode(LiveState.self, from: data)
    }

    static func saveLive(_ state: LiveState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: liveURL, options: .atomic)
        }
    }

    static func loadControl() -> ControlState {
        guard let data = try? Data(contentsOf: controlURL),
              let state = try? JSONDecoder().decode(ControlState.self, from: data) else { return ControlState() }
        return state
    }

    static func saveControl(_ state: ControlState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: controlURL, options: .atomic)
        }
    }

    static func defaultTitle(source: CaptureSource, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return "\(source.label) · \(formatter.string(from: date))"
    }

    // MARK: App group discovery

    /// AltStore/SideStore rename app groups when they re-sign (adding your team ID) and list the
    /// real names under `ALTAppGroups` in Info.plist. Try those first, then derive the suffix from
    /// the bundle ID, then fall back to the name the project was built with.
    private static func resolveAppGroup() -> String? {
        let fm = FileManager.default
        let host = containingAppBundle()
        var candidates: [String] = []

        for bundle in [Bundle.main, host] {
            if let groups = bundle.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] {
                candidates.append(contentsOf: groups)
            }
        }
        if let hostID = host.bundleIdentifier, hostID.hasPrefix(AppConstants.baseBundleID) {
            let suffix = String(hostID.dropFirst(AppConstants.baseBundleID.count))
            if !suffix.isEmpty { candidates.append(AppConstants.baseAppGroup + suffix) }
        }
        candidates.append(AppConstants.baseAppGroup)

        // Prefer groups that belong to this app over any other group the signer may have added.
        let ours = candidates.filter { $0.lowercased().contains("livescribe") }
        let others = candidates.filter { !$0.lowercased().contains("livescribe") }

        var seen = Set<String>()
        for id in ours + others where seen.insert(id).inserted {
            guard let url = fm.containerURL(forSecurityApplicationGroupIdentifier: id) else { continue }
            if isWritable(url) { return id }
        }
        return nil
    }

    static func containingAppBundle() -> Bundle {
        let url = Bundle.main.bundleURL
        if url.pathExtension == "appex" {
            let appURL = url.deletingLastPathComponent().deletingLastPathComponent()
            if let bundle = Bundle(url: appURL) { return bundle }
        }
        return Bundle.main
    }

    private static func isWritable(_ url: URL) -> Bool {
        let probe = url.appendingPathComponent(".livescribe-probe-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }
}
