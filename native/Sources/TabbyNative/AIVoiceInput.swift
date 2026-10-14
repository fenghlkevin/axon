import AVFoundation
import Speech
import SwiftUI

/// Dictation only edits the draft; it never submits prompts or approves operations.
@MainActor final class AIVoiceInput: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = ""
    @Published private(set) var settingsURL: URL?
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
            guard allowed else { status = "Allow Axon in System Settings → Privacy & Security → Speech Recognition / 请在系统设置 → 隐私与安全性 → 语音识别中允许 Axon"; settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"); return }
            let microphone = await microphonePermission()
            guard !Task.isCancelled, generation == token else { return }
            guard microphone else { status = "Allow Axon in System Settings → Privacy & Security → Microphone / 请在系统设置 → 隐私与安全性 → 麦克风中允许 Axon"; settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"); return }
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
                let failure = error.map { $0 as NSError }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if let text { self.transcript = String(text.prefix(8000)) }
                    if let failure { self.handleRecognitionError(failure) }
                    else if final { self.generation = UUID(); self.endCapture(); self.status = "Dictation ready; insert or discard / 听写完成，请插入或放弃" }
                }
            }
            do { engine.prepare(); try engine.start(); recording = true; status = "On-device dictation / 本机听写" }
            catch { handleRecognitionError(error as NSError) }
        }
    }
    func finish(_ insert: (String) -> Void) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop(); insert(text)
    }
    func stop() {
        generation = UUID(); permissionTask?.cancel(); permissionTask = nil
        endCapture(); transcript = ""; status = ""; settingsURL = nil
    }
    func handleRecognitionError(_ error: NSError) {
        generation = UUID()
        endCapture()
        settingsURL = nil
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 201):
            status = "Dictation is disabled. Enable Dictation in System Settings → Keyboard, then try again. / 系统听写已关闭。请在系统设置 → 键盘中开启「听写」，再重试。"
            settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        case ("kLSRErrorDomain", 102):
            status = "Download this language in System Settings → Keyboard → Dictation, then try again. / 请在系统设置 → 键盘 → 听写中下载当前语言资源，再重试。"
            settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        case ("kAFAssistantErrorDomain", 1110):
            status = "No speech detected. Check your microphone and try again. / 未识别到语音，请检查麦克风后重试。"
        default:
            status = "Voice input failed. Try again. / 语音输入失败，请重试。"
        }
    }
    private func endCapture() {
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; recording = false
    }
}

/// Recovery instructions wrap below the controls even in the terminal side panel.
struct AIVoiceStatusView: View {
    let message: String
    let settingsURL: URL?
    let chinese: Bool
    var openSettings: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let settingsURL {
                Button(chinese ? "打开系统设置" : "Open System Settings") { openSettings(settingsURL) }
                    .buttonStyle(ChromeButtonStyle()).accessibilityIdentifier("axon-ai-voice-settings")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
