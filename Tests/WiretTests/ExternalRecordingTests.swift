import XCTest
@testable import Wiret

final class ExternalRecordingTests: XCTestCase {
    private let voiceMemos = ExternalRecording.voiceMemosBundleID

    func testDetectsVoiceMemosRecording() {
        let processes = [
            AudioProcessInfo(bundleID: "com.apple.Music", isRunningInput: false),
            AudioProcessInfo(bundleID: voiceMemos, isRunningInput: true)
        ]

        XCTAssertTrue(ExternalRecording.isRecording(bundleID: voiceMemos, in: processes))
    }

    func testOpenButIdleVoiceMemosIsNotRecording() {
        let processes = [AudioProcessInfo(bundleID: voiceMemos, isRunningInput: false)]

        XCTAssertFalse(ExternalRecording.isRecording(bundleID: voiceMemos, in: processes))
    }

    func testMissingVoiceMemosIsNotRecording() {
        let processes = [AudioProcessInfo(bundleID: "com.apple.Music", isRunningInput: true)]

        XCTAssertFalse(ExternalRecording.isRecording(bundleID: voiceMemos, in: processes))
    }

    /// 마이크를 쓰는 아무 앱이나 막으면 화상 회의 중에 자동 녹음이 멈춘다.
    /// 정작 녹음이 가장 필요한 순간이므로 음성 메모만 본다.
    func testOtherAppsRecordingDoNotCount() {
        let processes = [
            AudioProcessInfo(bundleID: "us.zoom.xos", isRunningInput: true),
            AudioProcessInfo(bundleID: "com.tinyspeck.slackmacgap", isRunningInput: true),
            AudioProcessInfo(bundleID: voiceMemos, isRunningInput: false)
        ]

        XCTAssertFalse(ExternalRecording.isRecording(bundleID: voiceMemos, in: processes))
    }

    /// 번들 식별자가 없는 프로세스(명령줄 도구 등)도 섞여 들어온다.
    func testProcessesWithoutBundleIDAreIgnored() {
        let processes = [
            AudioProcessInfo(bundleID: nil, isRunningInput: true),
            AudioProcessInfo(bundleID: voiceMemos, isRunningInput: false)
        ]

        XCTAssertFalse(ExternalRecording.isRecording(bundleID: voiceMemos, in: processes))
    }

    func testEmptyProcessListIsNotRecording() {
        XCTAssertFalse(ExternalRecording.isRecording(bundleID: voiceMemos, in: []))
    }
}
