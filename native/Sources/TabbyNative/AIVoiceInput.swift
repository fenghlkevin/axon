import AVFoundation
import Speech
import SwiftUI

/// Dictation only edits the draft; it never submits prompts or approves operations.
@MainActor final class AIVoiceInput: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = ""
    private let speechPermission: () async -> Bool
    private let microphonePermission: () async -> Bool
    init(speechPermission: @escaping () async -> Bool = {
        await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) } }
    }, microphonePermission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.speechPermission = speechPermission; self.microphonePermission = microphonePermission
    }
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var permissionTask: Task<Void, Never>?
    private var installedTap = false
    private var generation = UUID()
    func start(chinese: Bool) {
        stop(); let token = UUID(); generation = token; status = "Requesting microphone access / 正在请求麦克风权限"
        permissionTask = Task {
            let allowed = await speechPermission()
            guard !Task.isCancelled, generation == token else { return }
            guard allowed else { status = "Allow speech recognition in macOS Settings / 请在系统设置中允许语音识别"; return }
            let microphone = await microphonePermission()
            guard !Task.isCancelled, generation == token else { return }
            guard microphone else { status = "Allow microphone access in macOS Settings / 请在系统设置中允许麦克风访问"; return }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: chinese ? "zh-CN" : "en-US")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                status = "On-device dictation is unavailable for this language / 当前语言的本机听写不可用"; return
            }
            let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { status = "No microphone available / 没有可用麦克风"; self.request = nil; return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; installedTap = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if let text { self.transcript = String(text.prefix(8000)) }
                    if final || message != nil { self.generation = UUID(); self.endCapture(); self.status = message ?? "Dictation ready; insert or discard / 听写完成，请插入或放弃" }
                }
            }
            do { engine.prepare(); try engine.start(); recording = true; status = "On-device dictation / 本机听写" }
            catch { endCapture(); status = error.localizedDescription }
        }
    }
    func finish(_ insert: (String) -> Void) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop(); insert(text)
    }
    func stop() {
        generation = UUID(); permissionTask?.cancel(); permissionTask = nil
        endCapture(); transcript = ""; status = ""
    }
    private func endCapture() {
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; recording = false
    }
}
