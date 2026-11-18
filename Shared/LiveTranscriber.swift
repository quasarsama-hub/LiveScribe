import Foundation
import AVFoundation
import Speech

/// Continuous speech-to-text on top of SFSpeechRecognizer.
///
/// Audio is cut into short recognition segments (at pauses when on-device, or every ~50 s) so long
/// sessions never hit per-request limits. While one segment is being finalized, incoming audio is
/// held in a backlog and fed to the next segment, so nothing is dropped between segments.
final class LiveTranscriber {
    /// `committed`: newly finalized lines, in order. `volatile`: text still being recognized.
    var onUpdate: ((_ committed: [String], _ volatile: String) -> Void)?
    var onStatus: ((String) -> Void)?

    private let queue: DispatchQueue
    private let callbackQueue: OperationQueue

    // Audio hand-off, guarded by `lock` (append() is called from audio threads).
    private let lock = NSLock()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var backlog: [AVAudioPCMBuffer] = []
    private var backlogFrames = 0
    private var acceptingAudio = false

    // Recognition state, confined to `queue`.
    private var language: TranscriptLanguage
    private var preferOnDevice: Bool
    private var recognizer: SFSpeechRecognizer?
    private var running = false
    private var generation = 0
    private var nextToCommit = 1
    private var currentGen = 0
    private var segments: [Int: Segment] = [:]
    private var lastChange = Date()
    private var timer: DispatchSourceTimer?
    private var restartScheduled = false
    private var rapidFailures = 0
    private var lastVolatile = ""
    private var lastStatus = ""
    private var stopCompletion: (() -> Void)?
    private var stopDeadline = Date.distantFuture

    private let pauseToCommit: TimeInterval = 1.4
    private let maxSegmentLength: TimeInterval = 50
    private let maxBacklogSeconds: Double = 20

    private struct Segment {
        var text = ""
        var done = false
        var ending = false
        var endRequestedAt: Date?
        var startedAt = Date()
        var onDevice = false
        var task: SFSpeechRecognitionTask?
        var request: SFSpeechAudioBufferRecognitionRequest?
        var recognizer: SFSpeechRecognizer?
    }

    init(language: TranscriptLanguage, preferOnDevice: Bool) {
        let dispatchQueue = DispatchQueue(label: "livescribe.transcriber")
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = dispatchQueue
        self.queue = dispatchQueue
        self.callbackQueue = operationQueue
        self.language = language
        self.preferOnDevice = preferOnDevice
    }

    // MARK: Public API (thread-safe)

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.lock.lock()
            self.acceptingAudio = true
            self.lock.unlock()
            self.startTimer()
            self.startSegment()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingAudio else { return }
        if let request = activeRequest {
            request.append(buffer)
        } else {
            backlog.append(buffer)
            backlogFrames += Int(buffer.frameLength)
            let limit = Int(buffer.format.sampleRate * maxBacklogSeconds)
            while backlogFrames > limit, !backlog.isEmpty {
                backlogFrames -= Int(backlog.removeFirst().frameLength)
            }
        }
    }

    func setLanguage(_ newLanguage: TranscriptLanguage) {
        queue.async {
            guard newLanguage != self.language else { return }
            self.language = newLanguage
            self.recognizer = nil
            if self.running { self.rotate() }
        }
    }

    func setPreferOnDevice(_ value: Bool) {
        queue.async {
            guard value != self.preferOnDevice else { return }
            self.preferOnDevice = value
            if self.running { self.rotate() }
        }
    }

    /// Finalizes in-flight text, then calls `completion` (on an internal queue) once everything has
    /// been delivered through `onUpdate`, or after `timeout`.
    func stop(timeout: TimeInterval = 2.0, completion: (() -> Void)? = nil) {
        queue.async {
            guard self.running else {
                completion?()
                return
            }
            self.running = false
            self.lock.lock()
            self.acceptingAudio = false
            let request = self.activeRequest
            self.activeRequest = nil
            self.backlog.removeAll()
            self.backlogFrames = 0
            self.lock.unlock()
            request?.endAudio()
            let now = Date()
            for (gen, segment) in self.segments where !segment.done {
                self.segments[gen]?.ending = true
                self.segments[gen]?.endRequestedAt = now
            }
            self.stopCompletion = completion
            self.stopDeadline = now.addingTimeInterval(timeout)
            self.checkStopped()
        }
    }

    // MARK: Segments

    private func startSegment() {
        restartScheduled = false
        guard running else { return }

        let auth = SFSpeechRecognizer.authorizationStatus()
        if auth == .denied || auth == .restricted {
            report("Speech recognition is off. Allow it in Settings › LiveScribe.")
            scheduleRestart(after: 5)
            return
        }
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: language.locale)
            recognizer?.queue = callbackQueue
        }
        guard let recognizer = recognizer else {
            report("\(language.label) recognition isn't available on this device.")
            scheduleRestart(after: 5)
            return
        }
        guard recognizer.isAvailable else {
            report("Recognizer not ready, retrying…")
            scheduleRestart(after: 2)
            return
        }

        generation += 1
        let gen = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        let onDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice

        var segment = Segment()
        segment.request = request
        segment.recognizer = recognizer
        segment.onDevice = onDevice
        segments[gen] = segment
        currentGen = gen
        lastChange = Date()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(gen: gen, result: result, error: error)
        }
        segments[gen]?.task = task

        lock.lock()
        for buffer in backlog { request.append(buffer) }
        backlog.removeAll()
        backlogFrames = 0
        activeRequest = request
        lock.unlock()

        if rapidFailures == 0 {
            report(onDevice ? "Listening · on-device" : "Listening · Apple servers")
        }
    }

    private func handle(gen: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        guard segments[gen] != nil else { return }

        if let result = result {
            let text = result.bestTranscription.formattedString
            if text != segments[gen]?.text {
                segments[gen]?.text = text
                if gen == currentGen { lastChange = Date() }
                if !text.isEmpty { rapidFailures = 0 }
            }
            if result.isFinal { segments[gen]?.done = true }
        }

        if let error = error as NSError? {
            let segment = segments[gen]
            segments[gen]?.done = true
            let failedFast = Date().timeIntervalSince(segment?.startedAt ?? Date()) < 1.0
            if failedFast, segment?.text.isEmpty ?? true, !(segment?.ending ?? false) {
                rapidFailures += 1
            }
            if !isRoutine(error) {
                var message = error.localizedDescription
                if message.localizedCaseInsensitiveContains("dictation") || message.localizedCaseInsensitiveContains("siri") {
                    message += " — turn on Dictation in Settings › General › Keyboard."
                }
                report(message)
            }
        }

        flush()

        if !running {
            checkStopped()
            return
        }
        if !hasPendingSegment && !restartScheduled {
            let delay = rapidFailures == 0 ? 0 : min(0.5 * pow(2, Double(rapidFailures - 1)), 8)
            scheduleRestart(after: delay)
        }
    }

    /// Ends the current segment; the next one starts as soon as it has finalized.
    private func rotate() {
        guard running else { return }
        guard let segment = segments[currentGen], !segment.done, !segment.ending else {
            if !hasPendingSegment && !restartScheduled { scheduleRestart(after: 0) }
            return
        }
        segments[currentGen]?.ending = true
        segments[currentGen]?.endRequestedAt = Date()
        lock.lock()
        activeRequest = nil
        lock.unlock()
        segment.request?.endAudio()
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard !restartScheduled else { return }
        restartScheduled = true
        lock.lock()
        activeRequest = nil
        lock.unlock()
        if delay <= 0 {
            queue.async { self.startSegment() }
        } else {
            queue.asyncAfter(deadline: .now() + delay) { self.startSegment() }
        }
    }

    private var hasPendingSegment: Bool {
        segments.values.contains { !$0.done }
    }

    private func flush() {
        var committed: [String] = []
        while let segment = segments[nextToCommit], segment.done {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { committed.append(text) }
            segments.removeValue(forKey: nextToCommit)
            nextToCommit += 1
        }
        let volatile = segments.keys.sorted()
            .compactMap { segments[$0]?.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !committed.isEmpty || volatile != lastVolatile {
            lastVolatile = volatile
            onUpdate?(committed, volatile)
        }
    }

    private func checkStopped() {
        guard !running, let completion = stopCompletion else { return }
        if Date() >= stopDeadline {
            for (gen, segment) in segments where !segment.done {
                segments[gen]?.done = true
                segment.task?.cancel()
            }
        }
        flush()
        if segments.isEmpty {
            stopCompletion = nil
            timer?.cancel()
            timer = nil
            completion()
        }
    }

    // MARK: Timer

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.4, repeating: 0.4)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        if running, let segment = segments[currentGen], !segment.done, !segment.ending {
            let quiet = now.timeIntervalSince(lastChange)
            let age = now.timeIntervalSince(segment.startedAt)
            let pauseCommit = segment.onDevice && !segment.text.isEmpty && quiet >= pauseToCommit
            if pauseCommit || age >= maxSegmentLength {
                rotate()
            }
        }
        // Watchdog: a segment that never finalizes must not block the ones after it.
        for (gen, segment) in segments where segment.ending && !segment.done {
            if let endedAt = segment.endRequestedAt, now.timeIntervalSince(endedAt) > 4 {
                segments[gen]?.done = true
                segment.task?.cancel()
            }
        }
        flush()
        if !running {
            checkStopped()
        } else if !hasPendingSegment && !restartScheduled {
            scheduleRestart(after: 0)
        }
    }

    // MARK: Helpers

    private func isRoutine(_ error: NSError) -> Bool {
        switch error.domain {
        case "kAFAssistantErrorDomain":
            // 1110 no speech, 216/209/203 cancel/retry, 1101/1107 benign framework noise
            return [203, 209, 216, 1101, 1107, 1110].contains(error.code)
        case "kLSRErrorDomain":
            return error.code == 301 // request canceled
        case "SFSpeechErrorDomain":
            return error.code == 1 || error.code == 301
        default:
            return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
        }
    }

    private func report(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }
}
