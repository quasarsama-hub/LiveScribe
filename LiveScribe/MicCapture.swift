import Foundation
import AVFoundation

struct MicError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Microphone capture that keeps running in the background (UIBackgroundModes: audio)
/// and mixes with audio from other apps instead of stopping it.
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onNotice: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var observers: [NSObjectProtocol] = []
    private var tapCount = 0
    private(set) var isRunning = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        try startEngine()
        isRunning = true
        observe()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        removeObservers()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicError("No microphone input is available.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self = self, let mono = AudioConvert.monoCopy(of: buffer) else { return }
            self.onBuffer?(mono)
            self.tapCount &+= 1
            if self.tapCount % 3 == 0 {
                self.onLevel?(AudioConvert.meterLevel(AudioConvert.rms(mono)))
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func observe() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            self?.restart()
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard isRunning,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            restart()
        } else {
            onNotice?("Paused by another app (call, Siri…)")
        }
    }

    private func restart() {
        guard isRunning else { return }
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
            onNotice?("")
        } catch {
            onNotice?("Microphone unavailable: \(error.localizedDescription)")
        }
    }
}
