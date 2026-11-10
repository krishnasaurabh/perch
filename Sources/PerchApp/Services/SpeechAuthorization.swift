import Speech

enum SFSpeechRecognizerBridge {
    static func request(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in done(s == .authorized) }
    }
}
