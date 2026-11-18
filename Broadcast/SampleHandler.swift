import ReplayKit
import AVFoundation
import CoreMedia
import Speech

/// Receives the audio of every app while a broadcast is running, transcribes it, and writes the
/// transcript into the shared container for the LiveScribe app to show and edit.
final class SampleHandler: RPBroadcastSampleHandler {
    private let stateQueue = DispatchQueue(label: "livescribe.broadcast.state")
    private var transcriber: LiveTranscriber?
    private var session: TranscriptSession?
    private var committedText = ""
    private var volatileText = ""
    private var status = "Starting…"
    private var language: TranscriptLanguage = .korean
    private var preferOnDevice = true
    private var level: Float = 0
    private var lastAudio: Date?
    private var lastLiveWrite = Date.distantPast
    private var tickCount = 0
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var finalized = false

    private let shutdownLock = NSLock()
    private var didShutdown = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let control = SharedStore.loadControl()
        let now = Date()
        let newSession = TranscriptSession(
            id: UUID(),
            title: SharedStore.defaultTitle(source: .system, date: now),
            createdAt: now,
            updatedAt: now,
            source: .system,
            language: control.language,
            text: "")

        let t = LiveTranscriber(language: control.language, preferOnDevice: control.preferOnDevice)
        t.onUpdate = { [weak self] committed, volatile in
            self?.stateQueue.async { self?.apply(committed: committed, volatile: volatile) }
        }
        t.onStatus = { [weak self] message in
            self?.stateQueue.async { self?.status = message }
        }

        stateQueue.sync {
            self.session = newSession
            self.language = control.language
            self.preferOnDevice = control.preferOnDevice
            self.transcriber = t
            SharedStore.save(newSession)
            self.writeLive(force: true, active: true)
        }
        t.start()
        startTimer()
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        shutdown()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp,
              let buffer = AudioConvert.monoBuffer(from: sampleBuffer) else { return }
        transcriber?.append(buffer)
        let rms = AudioConvert.rms(buffer)
        stateQueue.async {
            self.level = max(self.level, AudioConvert.meterLevel(rms))
            if rms > 0.0005 { self.lastAudio = Date() }
        }
    }

    // MARK: State (on stateQueue)

    private func apply(committed: [String], volatile: String) {
        guard !finalized, var current = session else { return }
        if !committed.isEmpty {
            let addition = committed.joined(separator: "\n")
            committedText = committedText.isEmpty ? addition : committedText + "\n" + addition
            current.text = committedText
            current.updatedAt = Date()
            session = current
            SharedStore.save(current)
        }
        volatileText = volatile
        writeLive(force: false, active: true)
    }

    private func writeLive(force: Bool, active: Bool) {
        guard let current = session else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastLiveWrite) < 0.25 { return }
        lastLiveWrite = now
        let state = LiveState(
            sessionID: current.id,
            isActive: active,
            committedTail: String(committedText.suffix(3000)),
            volatile: volatileText,
            status: status,
            heartbeat: now,
            language: language,
            level: level,
            lastAudio: lastAudio)
        SharedStore.saveLive(state)
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: stateQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !finished else { return }
        tickCount += 1
        if tickCount % 2 == 0 {
            let control = SharedStore.loadControl()
            if let current = session, control.stopRequestedFor == current.id {
                finished = true
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.stopFromApp() }
                return
            }
            if control.language != language {
                language = control.language
                transcriber?.setLanguage(control.language)
                if var current = session {
                    current.language = control.language
                    session = current
                    SharedStore.save(current)
                }
            }
            if control.preferOnDevice != preferOnDevice {
                preferOnDevice = control.preferOnDevice
                transcriber?.setPreferOnDevice(control.preferOnDevice)
            }
        }
        writeLive(force: true, active: true)
        level *= 0.6
    }

    // MARK: Shutdown

    private func stopFromApp() {
        shutdown()
        let error = NSError(
            domain: "LiveScribe",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Transcription stopped. Your transcript is saved in LiveScribe."])
        finishBroadcastWithError(error)
    }

    private func shutdown() {
        shutdownLock.lock()
        if didShutdown {
            shutdownLock.unlock()
            return
        }
        didShutdown = true
        shutdownLock.unlock()

        stateQueue.sync {
            self.finished = true
            self.timer?.cancel()
            self.timer = nil
        }

        if let t = transcriber {
            let done = DispatchSemaphore(value: 0)
            t.stop(timeout: 1.2) { done.signal() }
            _ = done.wait(timeout: .now() + 1.8)
        }

        stateQueue.sync {
            self.finalizeSession()
        }
    }

    private func finalizeSession() {
        guard !finalized, var current = session else { return }
        finalized = true
        let leftover = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            committedText = committedText.isEmpty ? leftover : committedText + "\n" + leftover
            volatileText = ""
        }
        current.text = committedText
        current.updatedAt = Date()
        session = current
        if committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SharedStore.delete(id: current.id)
        } else {
            SharedStore.save(current)
        }
        writeLive(force: true, active: false)
    }
}
