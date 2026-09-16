import AppKit
import XCTest
@testable import Wiret

private final class StubShortcutRunner: ShortcutRunning {
    var installedNames: [String] = [VoiceMemosImporter.defaultShortcutName]
    var resultToReturn = ShortcutRunResult(exitCode: 0, errorOutput: "")

    func shortcutNames() -> [String] { installedNames }

    func run(shortcutName: String, inputPath: String) -> ShortcutRunResult { resultToReturn }
}

final class AppDelegateTests: XCTestCase {
    private let suiteName = "WiretAppDelegateTests"
    private var delegate: AppDelegate!
    private var shortcutRunner: StubShortcutRunner!

    override func setUp() {
        super.setUp()
        setenv("WIRET_SUPPRESS_HIDDEN_ALERT", "1", 1)
        let testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
        _ = NSApplication.shared
        shortcutRunner = StubShortcutRunner()
        delegate = AppDelegate(
            defaults: testDefaults,
            voiceMemosImporter: VoiceMemosImporter(runner: shortcutRunner)
        )
        delegate.suppressAlertsForTesting = true
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    override func tearDown() {
        NSStatusBar.system.removeStatusItem(delegate.statusItem)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        shortcutRunner = nil
        delegate = nil
        super.tearDown()
    }

    func testMenuHasExpectedItems() {
        guard let menu = delegate.statusItem.menu else {
            XCTFail("menu missing")
            return
        }
        XCTAssertEqual(menu.items.count, 8)
        XCTAssertEqual(menu.items[0].title, "녹음 시작")
        XCTAssertEqual(menu.items[1].title, "녹음 중단")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].title, "자동")
        XCTAssertFalse(menu.items[4].isEnabled)
        XCTAssertEqual(menu.items[5].title, "음성 메모로 보내기")
        XCTAssertTrue(menu.items[6].isSeparatorItem)
        XCTAssertEqual(menu.items[7].title, "종료")
        XCTAssertFalse(menu.autoenablesItems)
    }

    func testAutoItemReflectsPersistedDisabledState() {
        XCTAssertEqual(delegate.autoItem.state, .off)
        XCTAssertEqual(delegate.autoItem.title, "자동")
    }

    func testAutoStatusItemIsDisabled() {
        XCTAssertFalse(delegate.autoStatusItem.isEnabled)
    }

    func testIdleMenuAvailability() {
        XCTAssertTrue(delegate.startItem.isEnabled)
        XCTAssertFalse(delegate.stopItem.isEnabled)
    }

    func testRecordingStateUpdatesMenuAndTint() {
        delegate.state = .recording
        XCTAssertFalse(delegate.startItem.isEnabled)
        XCTAssertTrue(delegate.stopItem.isEnabled)
        XCTAssertEqual(delegate.statusItem.button?.contentTintColor, .systemRed)

        delegate.state = .idle
        XCTAssertTrue(delegate.startItem.isEnabled)
        XCTAssertFalse(delegate.stopItem.isEnabled)
        XCTAssertNil(delegate.statusItem.button?.contentTintColor)
    }

    func testStatusItemButtonImageAndVisibility() {
        XCTAssertNotNil(delegate.statusItem.button?.image)
        XCTAssertTrue(delegate.statusItem.isVisible)
    }

    func testHandleUnexpectedStopResetsStateToIdle() {
        delegate.suppressAlertsForTesting = true
        delegate.state = .recording
        delegate.handleUnexpectedStop(nil)
        XCTAssertEqual(delegate.state, .idle)
        XCTAssertTrue(delegate.startItem.isEnabled)
        XCTAssertFalse(delegate.stopItem.isEnabled)
    }

    // MARK: - 음성 메모로 보내기

    private func toggleVoiceMemos() {
        guard let item = delegate.voiceMemosItem, let action = item.action else {
            return XCTFail("음성 메모 항목이 없습니다")
        }
        _ = delegate.perform(action)
    }

    func testVoiceMemosImportIsOffByDefault() {
        XCTAssertFalse(delegate.isVoiceMemosImportEnabled)
        XCTAssertEqual(delegate.voiceMemosItem.state, .off)
    }

    func testEnablingVoiceMemosImportRequiresTheShortcut() {
        shortcutRunner.installedNames = []

        toggleVoiceMemos()

        XCTAssertFalse(delegate.isVoiceMemosImportEnabled)
        XCTAssertEqual(delegate.voiceMemosItem.state, .off)
    }

    func testEnablingVoiceMemosImportSucceedsWhenShortcutExists() {
        toggleVoiceMemos()

        XCTAssertTrue(delegate.isVoiceMemosImportEnabled)
        XCTAssertEqual(delegate.voiceMemosItem.state, .on)
    }

    func testTogglingTwiceTurnsVoiceMemosImportOff() {
        toggleVoiceMemos()
        toggleVoiceMemos()

        XCTAssertFalse(delegate.isVoiceMemosImportEnabled)
        XCTAssertEqual(delegate.voiceMemosItem.state, .off)
    }

    /// 단축어가 사라진 뒤에도 켜져 있으면 녹음이 끝날 때마다 같은 실패가 반복된다.
    func testMissingShortcutFailureTurnsVoiceMemosImportOff() {
        toggleVoiceMemos()
        XCTAssertTrue(delegate.isVoiceMemosImportEnabled)

        delegate.handleVoiceMemosImportFailure(.shortcutMissing(VoiceMemosImporter.defaultShortcutName))

        XCTAssertFalse(delegate.isVoiceMemosImportEnabled)
        XCTAssertEqual(delegate.voiceMemosItem.state, .off)
    }

    /// 일시적인 실패로 설정까지 꺼 버리면 사용자가 매번 다시 켜야 한다.
    func testTransientFailureKeepsVoiceMemosImportOn() {
        toggleVoiceMemos()

        delegate.handleVoiceMemosImportFailure(.shortcutFailed("일시 오류"))

        XCTAssertTrue(delegate.isVoiceMemosImportEnabled)
    }
}
