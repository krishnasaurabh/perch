import Speech

enum SFSpeechRecognizerBridge {
    static func request(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            let granted = status == .authorized
            PlatformLog.speech.info("authorization completed status=\(status.rawValue, privacy: .public)")
            done(granted)
        }
    }
}
