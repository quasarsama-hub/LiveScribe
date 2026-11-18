import Foundation
import SwiftUI
import UIKit
import AVFoundation
import Speech

enum MicPhase {
    case idle, running, finishing
}

final class AppModel: ObservableObject {
    @Published private(set) var sessions: [TranscriptSession] = []
    @Published var language: TranscriptLanguage {
        didSet {
            guard oldValue != language else { return }
            persistControl()
            transcriber?.setLanguage(language)
        }
    }
    @Published var preferOnDevice: Bool {
        didSet {
            guard oldValue != preferOnDevice else { return }
            persistControl()
            transcriber?.setPreferOnDevice(preferOnDevice)
        }
    }

    // System audio (broadcast extension)
    @Published private(set) var systemLive: LiveState?
    @Published private(set) var systemStopRequested = false

    // Microphone
    @Published private(set) var micPhase: MicPhase = .idle
    @Published private(set) var micText = ""
    @Published private(set) var micVolatile = ""
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var micStatus = ""
    @Published private(set) var micNotice = ""

    @Published private(set) var speechAuth: SFSpeechRecognizerAuthorizationStatus
    @Published var errorMessage: String?

    let broadcastExtensionID: String? = AppModel.findBroadcastExtension()
    var sharedStorageOK: Bool { SharedStore.isShared }

    private var micSession: TranscriptSession?
    private var transcriber: LiveTranscriber?
    private let mic = MicCapture()
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let control = SharedStore.loadControl()
        language = control.language
        preferOnDevice = control.preferOnDevice
        speechAuth = SFSpeechRecognizer.authorizationStatus()
        sessions = SharedStore.loadSessions()

        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.becameActive()
        })
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollLive()
        }
        pollLive()
    }

    // MARK: Lifecycle

    func onLaunch() {
        if speechAuth == .notDetermined {
            requestSpeech { _ in }
        }
    }

    private func becameActive() {
        speechAuth = SFSpeechRecognizer.authorizationStatus()
        pollLive()
        reloadSessions()
    }

    func reloadSessions() {
        sessions = SharedStore.loadSessions()
    }

    var visibleSessions: [TranscriptSession] {
        let liveIDs = Set([micSession?.id, systemLive?.sessionID].compactMap { $0 })
        return sessions.filter { !liveIDs.contains($0.id) }
    }

    // MARK: Permissions

    func requestSpeech(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.speechAuth = status
                done(status == .authorized)
            }
        }
    }

    private func ensureMicPermissions(_ done: @escaping (Bool) -> Void) {
        let askMic: () -> Void = {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if !granted {
                        self.errorMessage = "Microphone access is off. Turn it on in Settings › LiveScribe."
                    }
                    done(granted)
                }
            }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            askMic()
        case .notDetermined:
            requestSpeech { ok in
                if ok {
                    askMic()
                } else {
                    self.errorMessage = "Speech recognition is off. Turn it on in Settings › LiveScribe."
                    done(false)
                }
            }
        default:
            errorMessage = "Speech recognition is off. Turn it on in Settings › LiveScribe."
            done(false)
        }
    }

    // MARK: Microphone mode

    func toggleMic() {
        switch micPhase {
        case .idle: startMic()
        case .running: stopMic()
        case .finishing: break
        }
    }

    private func startMic() {
        guard micPhase == .idle, systemLive == nil else { return }
        ensureMicPermissions { ok in
            if ok { self.beginMic() }
        }
    }

    private func beginMic() {
        guard micPhase == .idle else { return }
        let now = Date()
        let session = TranscriptSession(
            id: UUID(),
            title: SharedStore.defaultTitle(source: .microphone, date: now),
            createdAt: now,
            updatedAt: now,
            source: .microphone,
            language: language,
            text: "")

        let t = LiveTranscriber(language: language, preferOnDevice: preferOnDevice)
        t.onUpdate = { [weak self] committed, volatile in
            DispatchQueue.main.async { self?.applyMic(committed: committed, volatile: volatile) }
        }
        t.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.micStatus = status }
        }
        mic.onBuffer = { [weak t] buffer in t?.append(buffer) }
        mic.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.micLevel = level }
        }
        mic.onNotice = { [weak self] notice in
            DispatchQueue.main.async { self?.micNotice = notice }
        }

        do {
            try mic.start()
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        micSession = session
        micText = ""
        micVolatile = ""
        micNotice = ""
        micStatus = "Starting…"
        transcriber = t
        t.start()
        micPhase = .running
        SharedStore.save(session)
    }

    private func stopMic() {
        guard micPhase == .running else { return }
        mic.stop()
        micPhase = .finishing
        micLevel = 0
        let t = transcriber
        transcriber = nil
        if let t = t {
            t.stop(timeout: 2.0) { [weak self] in
                DispatchQueue.main.async { self?.finishMic() }
            }
        } else {
            finishMic()
        }
    }

    private func applyMic(committed: [String], volatile: String) {
        guard var session = micSession else { return }
        if !committed.isEmpty {
            let addition = committed.joined(separator: "\n")
            micText = micText.isEmpty ? addition : micText + "\n" + addition
            session.text = micText
            session.updatedAt = Date()
            micSession = session
            SharedStore.save(session)
        }
        micVolatile = volatile
    }

    private func finishMic() {
        if var session = micSession {
            let leftover = micVolatile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !leftover.isEmpty {
                micText = micText.isEmpty ? leftover : micText + "\n" + leftover
            }
            session.text = micText
            session.updatedAt = Date()
            if micText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SharedStore.delete(id: session.id)
            } else {
                SharedStore.save(session)
            }
        }
        micSession = nil
        micText = ""
        micVolatile = ""
        micStatus = ""
        micNotice = ""
        micPhase = .idle
        reloadSessions()
    }

    // MARK: System audio mode

    func stopSystem() {
        guard let id = systemLive?.sessionID else { return }
        var control = SharedStore.loadControl()
        control.stopRequestedFor = id
        SharedStore.saveControl(control)
        systemStopRequested = true
    }

    private func pollLive() {
        var fresh: LiveState?
        if let state = SharedStore.loadLive(), state.isActive,
           Date().timeIntervalSince(state.heartbeat) < 6 {
            fresh = state
        }
        let wasLive = systemLive != nil
        if fresh != systemLive { systemLive = fresh }
        if wasLive && fresh == nil {
            systemStopRequested = false
            reloadSessions()
        }
    }

    // MARK: Sessions

    func session(id: UUID) -> TranscriptSession? {
        sessions.first { $0.id == id } ?? SharedStore.loadSession(id: id)
    }

    func update(_ session: TranscriptSession) {
        var updated = session
        updated.updatedAt = Date()
        SharedStore.save(updated)
        if let index = sessions.firstIndex(where: { $0.id == updated.id }) {
            sessions[index] = updated
        }
    }

    func delete(ids: [UUID]) {
        ids.forEach { SharedStore.delete(id: $0) }
        sessions.removeAll { ids.contains($0.id) }
    }

    /// Full text of whatever is live right now (for the Copy button).
    func liveFullText() -> String {
        if micPhase != .idle {
            return [micText, micVolatile].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if let live = systemLive {
            let base = SharedStore.loadSession(id: live.sessionID)?.text ?? live.committedTail
            return [base, live.volatile].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: Settings

    private func persistControl() {
        var control = SharedStore.loadControl()
        control.language = language
        control.preferOnDevice = preferOnDevice
        SharedStore.saveControl(control)
    }

    func onDeviceSupported(_ language: TranscriptLanguage) -> Bool {
        SFSpeechRecognizer(locale: language.locale)?.supportsOnDeviceRecognition ?? false
    }

    private static func findBroadcastExtension() -> String? {
        guard let directory = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        for url in items where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let info = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  info["NSExtensionPointIdentifier"] as? String == "com.apple.broadcast-services-upload"
            else { continue }
            return bundle.bundleIdentifier
        }
        return nil
    }
}
