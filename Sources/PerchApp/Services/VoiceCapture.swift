import AVFoundation
import Combine
import Speech

// MARK: - On-device voice capture

@MainActor
final class VoiceCapture: ObservableObject {
    enum State: Equatable { case idle, listening, error(String) }
    @Published var state: State = .idle
    @Published var transcript = ""
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onFinish: ((String) -> Void)?

    func toggle(onFinish: @escaping (String) -> Void) {
        if state == .listening { stop() } else { Task { await start(onFinish: onFinish) } }
    }

    func start(onFinish: @escaping (String) -> Void) async {
        self.onFinish = onFinish
        transcript = ""
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            state = .error("Allow Speech Recognition for Perch under System Settings › Privacy & Security."); return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .error("Perch needs microphone access. Enable it under System Settings › Privacy & Security.");
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            state = .error("Speech recognition isn't available right now."); return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            state = .error(
                "Dictation for your language isn't installed on this Mac. Download it under System Settings › Keyboard › Dictation."
            )
            return
        }

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // never leaves the Mac
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { state = .error("Perch can't find a microphone."); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in request.append(buf) }
        do { try engine.start() } catch {
            state = .error("Recording failed to start: \(error.localizedDescription)"); return
        }

        self.engine = engine; self.request = request
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.transcript = result.bestTranscription.formattedString }
                if result?.isFinal == true || error != nil { self.finish() }
            }
        }
        // Stop on silence-ish: cap a single capture at 30 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.state == .listening { self?.stop() }
        }
    }

    func stop() {
        request?.endAudio()
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finish() }
    }

    private func finish() {
        guard state == .listening else { return }
        task?.cancel()
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0)
        engine = nil; request = nil; task = nil
        state = .idle
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { state = .error("Heard nothing usable. Tap the mic to retry.") } else { onFinish?(text) }
        onFinish = nil
    }
}
