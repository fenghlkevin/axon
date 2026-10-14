import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class AIVoiceRecoveryTests: XCTestCase {
    func testDisabledDictationRecoveryAndReset() {
        let voice = AIVoiceInput()
        voice.handleRecognitionError(NSError(domain: "kLSRErrorDomain", code: 201))
        XCTAssertTrue(voice.status.contains("系统听写已关闭"))
        XCTAssertTrue(voice.status.contains("键盘"))
        XCTAssertEqual(voice.settingsURL?.absoluteString, "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        XCTAssertFalse(voice.recording)
        voice.handleRecognitionError(NSError(domain: "kAFAssistantErrorDomain", code: 1110))
        XCTAssertNil(voice.settingsURL)
        XCTAssertTrue(voice.status.contains("未识别到语音"))
        voice.stop()
        XCTAssertTrue(voice.status.isEmpty)
        XCTAssertNil(voice.settingsURL)
    }

    func testRecoveryRenderingAndSettingsAction() async throws {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let voice = AIVoiceInput()
        voice.handleRecognitionError(NSError(domain: "kLSRErrorDomain", code: 201))
        let message = try XCTUnwrap(voice.status.components(separatedBy: " / ").last)
        try FileManager.default.createDirectory(atPath: "/tmp/axon-voice-recovery", withIntermediateDirectories: true)
        for width in [280, 480] {
            var opened: URL?
            let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
                Button("语音输入") {}.buttonStyle(ChromeButtonStyle())
                AIVoiceStatusView(message: message, settingsURL: voice.settingsURL, chinese: true, openSettings: { opened = $0 })
            }.padding(16).frame(width: CGFloat(width), height: 200).background(Palette.background))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/axon-voice-recovery/\(width).png"))
            var seen = Set<ObjectIdentifier>()
            func find(_ object: NSObject) -> NSObject? {
                guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
                if object.responds(to: NSSelectorFromString("accessibilityIdentifier")), object.value(forKey: "accessibilityIdentifier") as? String == "axon-ai-voice-settings" { return object }
                if object.responds(to: NSSelectorFromString("accessibilityChildren")), let children = object.value(forKey: "accessibilityChildren") as? [NSObject] {
                    for child in children { if let found = find(child) { return found } }
                }
                if let view = object as? NSView { for child in view.subviews { if let found = find(child) { return found } } }
                return nil
            }
            let button = try XCTUnwrap(find(host))
            let selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
            XCTAssertEqual(opened, voice.settingsURL)
        }
    }
}
