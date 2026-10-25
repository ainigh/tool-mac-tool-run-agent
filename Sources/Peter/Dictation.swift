import AVFoundation
import Foundation
import Speech

/// Speaking to Peter instead of typing: the microphone, written down by macOS's own speech
/// recognition (on this Mac when it can be). What's heard shows as it's heard; when the speaking
/// stops (a pause, or the button again) it's sent.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    /// What's been heard so far.
    @Published private(set) var heard = ""
    @Published var problem: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var silence: Timer?
    private var onDone: ((String) -> Void)?

    /// Starts listening; `done` gets what was said once the speaking stops.
    func start(done: @escaping (String) -> Void) {
        guard !listening else { return }
        problem = nil
        onDone = done
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard status == .authorized else {
                        self.problem = "Peter isn't allowed to use speech recognition: System Settings › Privacy & Security › Speech Recognition."
                        return
                    }
                    AVCaptureDevice.requestAccess(for: .audio) { ok in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard ok else {
                                    self.problem = "Peter isn't allowed to use the microphone: System Settings › Privacy & Security › Microphone."
                                    return
                                }
                                self.begin()
                            }
                        }
                    }
                }
            }
        }
    }

    private func begin() {
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            problem = "The microphone didn't start: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            return
        }
        heard = ""
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listening else { return }
                    if let text {
                        self.heard = text
                        self.waitForSilence()
                    }
                    if final || error != nil { self.stop() }
                }
            }
        }
        waitForSilence(first: true)
    }

    /// A pause in the speaking ends it (longer before the first word).
    private func waitForSilence(first: Bool = false) {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: first ? 6 : 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Stops listening, and sends what was heard.
    func stop() {
        guard listening else { return }
        listening = false
        silence?.invalidate()
        silence = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        if !said.isEmpty { onDone?(said) }
        onDone = nil
    }

    /// Stops listening without sending anything.
    func cancel() {
        heard = ""
        onDone = nil
        stop()
    }
}
