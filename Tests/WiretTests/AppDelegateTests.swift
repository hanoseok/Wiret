import AppKit
import XCTest
@testable import Wiret

private final class StubShortcutRunner: ShortcutRunning {
    var installedNames: [String] = [VoiceMemosImporter.defaultShortcutName]
    var resultToReturn = ShortcutRunResult(exitCode: 0, errorOutput: "")

    func shortcutNames() -> [String] { installedNames }

    func run(shortcutName: String, inputPath: String) -> ShortcutRunResult { resultToReturn }
}

private final class StubShortcutInstaller: ShortcutInstalling {
    var signResult = ShortcutRunResult(exitCode: 0, errorOutput: "")
    private(set) var signCount = 0
    private(set) var openedURLs: [URL] = []
    private(set) var viewedNames: [String] = []

    func sign(unsigned: URL, signed: URL) -> ShortcutRunResult {
        signCount += 1
        // 서명 성공을 흉내내려면 출력 파일이 있어야 한다.
        try? Data("signed".utf8).write(to: signed)
        return signResult
    }

    func open(_ url: URL) { openedURLs.append(url) }

    func view(shortcutNamed name: String) -> ShortcutRunResult {
        viewedNames.append(name)
        return ShortcutRunResult(exitCode: 0, errorOutput: "")
    }
}

/// 버전 표시 테스트에서만 쓴다. 네트워크를 타지 않도록 빈 목록만 돌려준다.
private final class FakeUpdateCheckerForVersionTest: UpdateChecking {
    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateError>) -> Void) {
        completion(.success([]))
    }

    func download(_ release: ReleaseInfo, completion: @escaping (Result<URL, UpdateError>) -> Void) {
        completion(.failure(.network("테스트에서는 내려받지 않습니다")))
    }
}

/// 메뉴 안 업데이트 확인 테스트에서 쓴다. 결과를 바로 돌려주거나, 붙잡아 두었다가 나중에 돌려준다.
private final class StubUpdateChecker: UpdateChecking {
    var releasesResult: Result<[ReleaseInfo], UpdateError> = .success([])
    var downloadResult: Result<URL, UpdateError> = .failure(.network("테스트에서는 내려받지 않습니다"))
    /// 켜 두면 결과를 붙잡아 "확인 중"·"내려받는 중" 상태를 관찰할 수 있다.
    var holdsCompletions = false
    private(set) var downloadedReleases: [ReleaseInfo] = []
    private var pendingFetches: [(Result<[ReleaseInfo], UpdateError>) -> Void] = []
    private var pendingDownloads: [(Result<URL, UpdateError>) -> Void] = []

    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateError>) -> Void) {
        if holdsCompletions {
            pendingFetches.append(completion)
        } else {
            completion(releasesResult)
        }
    }

    func download(_ release: ReleaseInfo, completion: @escaping (Result<URL, UpdateError>) -> Void) {
        downloadedReleases.append(release)
        if holdsCompletions {
            pendingDownloads.append(completion)
        } else {
            completion(downloadResult)
        }
    }

    func finishFetches() {
        let completions = pendingFetches
        pendingFetches = []
        completions.forEach { $0(releasesResult) }
    }

    func finishDownloads() {
        let completions = pendingDownloads
        pendingDownloads = []
        completions.forEach { $0(downloadResult) }
    }
}

private final class StubMeetingSource: MeetingSource {
    var onChange: (() -> Void)?
    var availableCalendars: [CalendarInfo] = []
    var selectedCalendarIDs: Set<String> = []

    var meetingsToReturn: [Meeting] = []

    func requestAccess(completion: @escaping (Bool) -> Void) { completion(true) }
    func meetings(from: Date, to: Date) -> [Meeting] { meetingsToReturn }
}

/// 실제 `SMAppService`는 이 Mac의 로그인 항목을 바꾸므로 테스트의 모든 AppDelegate는 이 가짜를 받는다.
private final class FakeLaunchAtLogin: LaunchAtLoginControlling {
    var status: LaunchAtLoginStatus = .notRegistered
    /// 등록이 끝난 뒤 보고할 상태. 관리 정책 때문에 허용을 기다리는 경우를 흉내 낼 때 바꾼다.
    var statusAfterRegister: LaunchAtLoginStatus = .enabled
    var errorToThrow: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSystemSettingsCount = 0

    func register() throws {
        registerCount += 1
        if let errorToThrow { throw errorToThrow }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let errorToThrow { throw errorToThrow }
        status = .notRegistered
    }

    func openSystemSettings() { openSystemSettingsCount += 1 }
}

private struct LaunchAtLoginTestError: Error {}

final class AppDelegateTests: XCTestCase {
    private let suiteName = "WiretAppDelegateTests"
    private var delegate: AppDelegate!
    private var shortcutRunner: StubShortcutRunner!
    private var shortcutInstaller: StubShortcutInstaller!
    private var calendarSource: StubMeetingSource!
    private var launchAtLogin: FakeLaunchAtLogin!

    override func setUp() {
        super.setUp()
        setenv("WIRET_SUPPRESS_HIDDEN_ALERT", "1", 1)
        let testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
        _ = NSApplication.shared
        shortcutRunner = StubShortcutRunner()
        shortcutInstaller = StubShortcutInstaller()
        calendarSource = StubMeetingSource()
        launchAtLogin = FakeLaunchAtLogin()
        calendarSource.availableCalendars = [
            CalendarInfo(id: "work", title: "업무", sourceTitle: "aston@kakaocorp.com"),
            CalendarInfo(id: "personal", title: "개인", sourceTitle: "aston@gmail.com")
        ]
        delegate = AppDelegate(
            defaults: testDefaults,
            voiceMemosImporter: VoiceMemosImporter(runner: shortcutRunner),
            shortcutInstaller: VoiceMemosShortcutInstaller(installer: shortcutInstaller),
            calendarSource: calendarSource,
            launchAtLogin: launchAtLogin
        )
        delegate.suppressAlertsForTesting = true
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    }

    override func tearDown() {
        NSStatusBar.system.removeStatusItem(delegate.statusItem)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        shortcutRunner = nil
        shortcutInstaller = nil
        calendarSource = nil
        launchAtLogin = nil
        delegate = nil
        super.tearDown()
    }

    func testMenuHasExpectedItems() {
        guard let menu = delegate.statusItem.menu else {
            XCTFail("menu missing")
            return
        }
        XCTAssertEqual(menu.items.count, 15)
        XCTAssertEqual(menu.items[0].title, "녹음 시작")
        XCTAssertEqual(menu.items[1].title, "녹음 중단")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].title, "자동")
        XCTAssertEqual(menu.items[4].title, "알림")
        XCTAssertEqual(menu.items[5].title, "로그인 시 실행")
        XCTAssertFalse(menu.items[6].isEnabled)
        XCTAssertEqual(menu.items[7].title, "캘린더")
        XCTAssertNotNil(menu.items[7].submenu)
        XCTAssertEqual(menu.items[8].title, "오늘의 일정")
        XCTAssertEqual(menu.items[9].title, "업데이트 확인")
        XCTAssertEqual(menu.items[10].title, delegate.versionItem.title)
        XCTAssertFalse(menu.items[10].isEnabled)
        XCTAssertEqual(menu.items[11].title, "음성 메모로 보내기")
        XCTAssertEqual(menu.items[12].title, "음성 메모 단축어 삭제")
        XCTAssertTrue(menu.items[13].isSeparatorItem)
        XCTAssertEqual(menu.items[14].title, "종료")
        XCTAssertFalse(menu.autoenablesItems)
    }

    /// XCTest 번들에는 `WiretVersion`이 없으므로 기본 delegate는 로컬 빌드로 취급된다.
    func testVersionItemShowsLocalBuildTitleByDefault() {
        XCTAssertEqual(delegate.versionItem.title, "현재 버전: 로컬 빌드 (자동 업데이트 꺼짐)")
        XCTAssertFalse(delegate.versionItem.isEnabled)
        XCTAssertFalse(delegate.updateItem.isEnabled)
    }

    func testVersionTitleForSnapshotVersion() {
        let version = AppVersion.parse("0.0.11-SNAPSHOT")
        XCTAssertEqual(AppDelegate.versionTitle(for: version), "현재 버전: 0.0.11-SNAPSHOT")
    }

    func testVersionTitleForReleaseVersion() {
        let version = AppVersion.parse("1.0.0")
        XCTAssertEqual(AppDelegate.versionTitle(for: version), "현재 버전: 1.0.0")
    }

    func testVersionTitleForNilVersion() {
        XCTAssertEqual(AppDelegate.versionTitle(for: nil), "현재 버전: 로컬 빌드 (자동 업데이트 꺼짐)")
    }

    /// 채널을 아는 빌드라면 버전 문구가 실제 버전을 보여준다.
    func testVersionItemShowsCurrentVersionWhenKnown() {
        let checker = FakeUpdateCheckerForVersionTest()
        let coordinator = UpdateCoordinator(
            currentVersion: AppVersion.parse("0.0.11-SNAPSHOT"),
            checker: checker,
            bundleURL: URL(fileURLWithPath: "/tmp/Wiret.app")
        )
        let versionedDelegate = AppDelegate(
            defaults: UserDefaults(suiteName: suiteName)!,
            voiceMemosImporter: VoiceMemosImporter(runner: shortcutRunner),
            shortcutInstaller: VoiceMemosShortcutInstaller(installer: shortcutInstaller),
            calendarSource: calendarSource,
            launchAtLogin: launchAtLogin,
            updateCoordinator: coordinator
        )
        versionedDelegate.suppressAlertsForTesting = true
        versionedDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        defer { NSStatusBar.system.removeStatusItem(versionedDelegate.statusItem) }

        XCTAssertEqual(versionedDelegate.versionItem.title, "현재 버전: 0.0.11-SNAPSHOT")
        XCTAssertTrue(versionedDelegate.updateItem.isEnabled)
    }

    // MARK: - 메뉴 안에서 업데이트 확인

    private func release(_ tag: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion.parse(tag)!,
            downloadURL: URL(string: "https://example.com/\(tag).zip")!,
            pageURL: nil
        )
    }

    /// 배포 빌드처럼 버전을 아는 delegate를 띄운다. 실행 직후의 자동 확인까지 끝난 상태로 돌려준다.
    private func makeVersionedDelegate(checker: StubUpdateChecker) -> AppDelegate {
        let coordinator = UpdateCoordinator(
            currentVersion: AppVersion.parse("0.0.12-SNAPSHOT"),
            checker: checker,
            bundleURL: URL(fileURLWithPath: "/tmp/Wiret.app")
        )
        let versionedDelegate = AppDelegate(
            defaults: UserDefaults(suiteName: suiteName)!,
            voiceMemosImporter: VoiceMemosImporter(runner: shortcutRunner),
            shortcutInstaller: VoiceMemosShortcutInstaller(installer: shortcutInstaller),
            calendarSource: calendarSource,
            launchAtLogin: launchAtLogin,
            updateCoordinator: coordinator
        )
        versionedDelegate.suppressAlertsForTesting = true
        versionedDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        addTeardownBlock { NSStatusBar.system.removeStatusItem(versionedDelegate.statusItem) }
        drainMainQueue()
        return versionedDelegate
    }

    /// 업데이트 콜백은 메인 큐로 넘어와 반영된다. 그 뒤에 줄 선 블록이 돌면 앞선 반영도 끝난 것이다.
    private func drainMainQueue() {
        let drained = expectation(description: "메인 큐 비우기")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func clickUpdateItem(of delegate: AppDelegate) {
        guard let view = delegate.updateItem.view as? MenuActionItemView else {
            XCTFail("업데이트 확인 항목에 뷰가 없습니다")
            return
        }
        view.performClick()
    }

    /// 일반 항목은 누르면 메뉴가 닫힌다. 뷰를 달아야 확인하는 동안 메뉴가 열려 있다.
    func testUpdateItemUsesViewThatKeepsMenuOpen() {
        XCTAssertTrue(delegate.updateItem.view is MenuActionItemView)
    }

    /// 로컬 빌드는 확인할 수 없으니 뷰도 눌리지 않아야 한다.
    func testUpdateItemViewIsDisabledForLocalBuild() {
        let view = delegate.updateItem.view as? MenuActionItemView
        XCTAssertEqual(view?.isEnabled, false)
        XCTAssertNotNil(view?.toolTip)
        XCTAssertEqual(delegate.updateItem.title, "업데이트 확인")
    }

    func testManualCheckShowsUpToDateInline() {
        let checker = StubUpdateChecker()
        let versionedDelegate = makeVersionedDelegate(checker: checker)

        clickUpdateItem(of: versionedDelegate)
        drainMainQueue()

        XCTAssertEqual(versionedDelegate.updateItem.title, "최신 버전입니다")
        XCTAssertEqual((versionedDelegate.updateItem.view as? MenuActionItemView)?.title, "최신 버전입니다")
        XCTAssertTrue(versionedDelegate.updateItem.isEnabled, "다시 눌러 확인할 수 있어야 합니다")
        XCTAssertNil(versionedDelegate.updateAvailableItem)
        XCTAssertEqual(versionedDelegate.statusItem.menu?.items.count, 15)
    }

    func testManualCheckShowsUpdateButtonRightAfterUpdateItem() {
        let checker = StubUpdateChecker()
        let versionedDelegate = makeVersionedDelegate(checker: checker)
        checker.releasesResult = .success([release("0.0.13-SNAPSHOT")])

        clickUpdateItem(of: versionedDelegate)
        drainMainQueue()

        guard let menu = versionedDelegate.statusItem.menu,
              let button = versionedDelegate.updateAvailableItem else {
            XCTFail("업데이트 버튼이 없습니다")
            return
        }
        let updateIndex = menu.index(of: versionedDelegate.updateItem)
        XCTAssertEqual(menu.index(of: button), updateIndex + 1)
        XCTAssertEqual(menu.index(of: versionedDelegate.versionItem), updateIndex + 2)
        XCTAssertEqual(button.title, "0.0.13-SNAPSHOT으로 업데이트")
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(versionedDelegate.updateItem.title, "업데이트 확인")
        XCTAssertEqual(menu.items.count, 16)
    }

    func testManualCheckFailureShowsRetryTitle() {
        let checker = StubUpdateChecker()
        let versionedDelegate = makeVersionedDelegate(checker: checker)
        checker.releasesResult = .failure(.badResponse(403))

        clickUpdateItem(of: versionedDelegate)
        drainMainQueue()

        XCTAssertEqual(versionedDelegate.updateItem.title, "업데이트 확인 실패 · 다시 시도")
        XCTAssertTrue(versionedDelegate.updateItem.isEnabled)
        XCTAssertEqual(
            versionedDelegate.updateItem.view?.toolTip,
            UpdateError.badResponse(403).errorDescription
        )
        XCTAssertNil(versionedDelegate.updateAvailableItem)
    }

    /// 확인하는 동안 또 누르면 같은 요청이 겹친다.
    func testUpdateItemIsDisabledWhileChecking() {
        let checker = StubUpdateChecker()
        let versionedDelegate = makeVersionedDelegate(checker: checker)
        checker.holdsCompletions = true

        clickUpdateItem(of: versionedDelegate)
        drainMainQueue()

        XCTAssertEqual(versionedDelegate.updateItem.title, "업데이트 확인 중…")
        XCTAssertFalse(versionedDelegate.updateItem.isEnabled)
        XCTAssertEqual((versionedDelegate.updateItem.view as? MenuActionItemView)?.isEnabled, false)

        checker.finishFetches()
        drainMainQueue()

        XCTAssertEqual(versionedDelegate.updateItem.title, "최신 버전입니다")
    }

    /// 며칠 지난 "최신 버전입니다"가 남으면 지금도 최신인 것처럼 읽힌다.
    func testMenuWillOpenResetsFinishedStatus() {
        let checker = StubUpdateChecker()
        let versionedDelegate = makeVersionedDelegate(checker: checker)
        clickUpdateItem(of: versionedDelegate)
        drainMainQueue()
        XCTAssertEqual(versionedDelegate.updateItem.title, "최신 버전입니다")

        versionedDelegate.menuWillOpen(versionedDelegate.statusItem.menu!)

        XCTAssertEqual(versionedDelegate.updateItem.title, "업데이트 확인")
        XCTAssertTrue(versionedDelegate.updateItem.isEnabled)
    }

    /// 확인이 아직 끝나지 않았다면 메뉴를 다시 열어도 진행 중임을 보여 줘야 한다.
    func testMenuWillOpenKeepsCheckingStatus() {
        let checker = StubUpdateChecker()
        let versionedDelegate = makeVersionedDelegate(checker: checker)
        checker.holdsCompletions = true
        clickUpdateItem(of: versionedDelegate)

        versionedDelegate.menuWillOpen(versionedDelegate.statusItem.menu!)

        XCTAssertEqual(versionedDelegate.updateItem.title, "업데이트 확인 중…")
    }

    /// 자동 확인은 창으로 묻고, 창을 닫은 뒤에도 메뉴에서 업데이트할 수 있게 버튼을 남긴다.
    func testAutomaticCheckFindingUpdateShowsButton() {
        let checker = StubUpdateChecker()
        checker.releasesResult = .success([release("0.0.13-SNAPSHOT")])

        let versionedDelegate = makeVersionedDelegate(checker: checker)

        XCTAssertEqual(versionedDelegate.updateAvailableItem?.title, "0.0.13-SNAPSHOT으로 업데이트")
        XCTAssertEqual(versionedDelegate.updateItem.title, "업데이트 확인")
    }

    /// 버튼은 하나만 두고, 더 새 버전이 나오면 그 버튼을 고쳐 쓴다.
    func testNewerReleaseUpdatesExistingButton() {
        let checker = StubUpdateChecker()
        checker.releasesResult = .success([release("0.0.13-SNAPSHOT")])
        let versionedDelegate = makeVersionedDelegate(checker: checker)

        checker.releasesResult = .success([release("0.0.13-SNAPSHOT"), release("0.0.14-SNAPSHOT")])
        clickUpdateItem(of: versionedDelegate)
        drainMainQueue()

        let menu = versionedDelegate.statusItem.menu!
        XCTAssertEqual(menu.items.filter { $0.title.hasSuffix("으로 업데이트") }.count, 1)
        XCTAssertEqual(versionedDelegate.updateAvailableItem?.title, "0.0.14-SNAPSHOT으로 업데이트")
        XCTAssertEqual(menu.items.count, 16)
    }

    /// 내려받는 동안에는 또 누르지 못하게 막고, 실패하면 다시 누를 수 있게 되돌린다.
    func testUpdateButtonShowsDownloadingAndRecoversFromFailure() {
        let checker = StubUpdateChecker()
        checker.releasesResult = .success([release("0.0.13-SNAPSHOT")])
        let versionedDelegate = makeVersionedDelegate(checker: checker)
        checker.holdsCompletions = true
        guard let menu = versionedDelegate.statusItem.menu,
              let button = versionedDelegate.updateAvailableItem else {
            XCTFail("업데이트 버튼이 없습니다")
            return
        }

        menu.performActionForItem(at: menu.index(of: button))

        XCTAssertEqual(checker.downloadedReleases.map(\.version.description), ["0.0.13-SNAPSHOT"])
        XCTAssertEqual(button.title, "업데이트 내려받는 중…")
        XCTAssertFalse(button.isEnabled)

        checker.downloadResult = .failure(.badResponse(404))
        checker.finishDownloads()
        drainMainQueue()

        XCTAssertEqual(button.title, "0.0.13-SNAPSHOT으로 업데이트")
        XCTAssertTrue(button.isEnabled)
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

    // MARK: - 단축어 설치/삭제

    private func toggleShortcutItem() {
        guard let action = delegate.shortcutItem?.action else {
            return XCTFail("단축어 항목이 없습니다")
        }
        _ = delegate.perform(action)
    }

    /// 설치와 삭제 중 지금 할 수 있는 쪽 하나만 보여야 한다.
    func testShortcutItemShowsInstallWhenMissing() {
        shortcutRunner.installedNames = []
        delegate.refreshShortcutItem()

        XCTAssertEqual(delegate.shortcutItem.title, "음성 메모 단축어 설치")
    }

    func testShortcutItemShowsRemoveWhenInstalled() {
        delegate.refreshShortcutItem()

        XCTAssertEqual(delegate.shortcutItem.title, "음성 메모 단축어 삭제")
    }

    /// 단축어는 Wiret 밖에서도 추가·삭제되므로 메뉴를 열 때 상태를 다시 읽어야 한다.
    func testMenuWillOpenRefreshesShortcutItem() {
        XCTAssertEqual(delegate.shortcutItem.title, "음성 메모 단축어 삭제")

        shortcutRunner.installedNames = []
        delegate.menuWillOpen(NSMenu())

        XCTAssertEqual(delegate.shortcutItem.title, "음성 메모 단축어 설치")
    }

    func testInstallingSignsAndHandsFileToShortcutsApp() {
        shortcutRunner.installedNames = []
        delegate.refreshShortcutItem()

        toggleShortcutItem()

        XCTAssertEqual(shortcutInstaller.signCount, 1)
        XCTAssertEqual(shortcutInstaller.openedURLs.count, 1)
        XCTAssertEqual(shortcutInstaller.openedURLs.first?.pathExtension, "shortcut")
    }

    /// 서명이 실패했는데 단축어 앱을 여는 것은 사용자를 헷갈리게 한다.
    func testFailedSigningDoesNotOpenShortcutsApp() {
        shortcutRunner.installedNames = []
        shortcutInstaller.signResult = ShortcutRunResult(exitCode: 1, errorOutput: "형식 오류")
        delegate.refreshShortcutItem()

        toggleShortcutItem()

        XCTAssertTrue(shortcutInstaller.openedURLs.isEmpty)
    }

    func testRemovingOpensShortcutInShortcutsApp() {
        delegate.refreshShortcutItem()

        toggleShortcutItem()

        XCTAssertEqual(shortcutInstaller.viewedNames, [VoiceMemosImporter.defaultShortcutName])
        XCTAssertEqual(shortcutInstaller.signCount, 0)
    }

    // MARK: - 자동 녹음과 단축어

    /// 자동 녹음을 켜는 시점에는 단축어가 준비돼 있어야 한다.
    func testEnablingAutoInstallsShortcutWhenMissing() {
        shortcutRunner.installedNames = []

        delegate.perform(#selector(AppDelegate.toggleAutoForTesting))

        XCTAssertEqual(shortcutInstaller.signCount, 1)
        XCTAssertEqual(delegate.autoItem.state, .on)
    }

    func testEnablingAutoDoesNotReinstallExistingShortcut() {
        delegate.perform(#selector(AppDelegate.toggleAutoForTesting))

        XCTAssertEqual(shortcutInstaller.signCount, 0)
        XCTAssertEqual(delegate.autoItem.state, .on)
    }

    /// 자동을 끌 때는 단축어를 건드릴 이유가 없다.
    func testDisablingAutoDoesNotInstallShortcut() {
        shortcutRunner.installedNames = []
        delegate.perform(#selector(AppDelegate.toggleAutoForTesting))  // 켜기
        let afterEnable = shortcutInstaller.signCount

        delegate.perform(#selector(AppDelegate.toggleAutoForTesting))  // 끄기

        XCTAssertEqual(shortcutInstaller.signCount, afterEnable)
        XCTAssertEqual(delegate.autoItem.state, .off)
    }

    // MARK: - 회의 알림

    func testNotificationItemIsOffByDefault() {
        XCTAssertEqual(delegate.notificationItem.title, "알림")
        XCTAssertEqual(delegate.notificationItem.state, .off)
        XCTAssertFalse(delegate.meetingNotifier.isEnabled)
    }

    func testTogglingNotificationsTurnsThemOnAndOff() {
        delegate.perform(#selector(AppDelegate.toggleNotificationsForTesting))

        XCTAssertTrue(delegate.meetingNotifier.isEnabled)
        XCTAssertEqual(delegate.notificationItem.state, .on)

        delegate.perform(#selector(AppDelegate.toggleNotificationsForTesting))

        XCTAssertFalse(delegate.meetingNotifier.isEnabled)
        XCTAssertEqual(delegate.notificationItem.state, .off)
    }

    /// 알림을 켜 둔 상태는 앱을 다시 켜도 유지돼야 한다.
    func testNotificationsSurviveRelaunch() {
        delegate.perform(#selector(AppDelegate.toggleNotificationsForTesting))

        let relaunched = AppDelegate(
            defaults: UserDefaults(suiteName: suiteName)!,
            voiceMemosImporter: VoiceMemosImporter(runner: shortcutRunner),
            shortcutInstaller: VoiceMemosShortcutInstaller(installer: shortcutInstaller),
            calendarSource: calendarSource,
            launchAtLogin: launchAtLogin
        )

        XCTAssertTrue(relaunched.meetingNotifier.isEnabled)
    }

    /// 알림을 켜는 것은 자동 녹음과 별개다.
    func testEnablingNotificationsLeavesAutoOff() {
        delegate.perform(#selector(AppDelegate.toggleNotificationsForTesting))

        XCTAssertFalse(delegate.coordinator.isEnabled)
        XCTAssertEqual(delegate.autoItem.state, .off)
    }

    /// 두 코디네이터 모두 캘린더 변경을 받아야 한다. 나중에 만든 쪽이 덮어쓰면 한쪽이 멈춘다.
    func testCalendarChangeReachesNotifier() {
        let start = Date().addingTimeInterval(-60)
        let meeting = Meeting(id: "m1", title: "회의", start: start, end: start.addingTimeInterval(1800))
        delegate.perform(#selector(AppDelegate.toggleNotificationsForTesting))
        XCTAssertNil(delegate.meetingNotifier.pendingPrompt)

        calendarSource.meetingsToReturn = [meeting]
        calendarSource.onChange?()

        XCTAssertEqual(delegate.meetingNotifier.pendingPrompt, .start(meeting))
    }

    /// 녹음이 예기치 않게 끝나면 떠 있던 종료 알림은 물을 게 없어진다.
    func testUnexpectedStopClearsEndPrompt() {
        let start = Date().addingTimeInterval(-600)
        calendarSource.meetingsToReturn = [
            Meeting(id: "m1", title: "회의", start: start, end: start.addingTimeInterval(1800))
        ]
        delegate.state = .recording
        delegate.perform(#selector(AppDelegate.toggleNotificationsForTesting))
        XCTAssertEqual(delegate.meetingNotifier.trackedMeetingId, "m1")

        // 캘린더에서 회의를 앞당겨 끝낸 것처럼 종료 시각을 지금 이전으로 바꾼다.
        let ended = Meeting(id: "m1", title: "회의", start: start, end: start.addingTimeInterval(300))
        calendarSource.meetingsToReturn = [ended]
        calendarSource.onChange?()
        XCTAssertEqual(delegate.meetingNotifier.pendingPrompt, .end(ended))

        delegate.handleUnexpectedStop(nil)

        XCTAssertNil(delegate.meetingNotifier.pendingPrompt)
    }

    /// 알림이 켜져 있으면 자동 녹음도 회의가 끝날 때 멈추지 않고 종료 알림으로 묻는다.
    func testAutoRecordingEndShowsEndPromptWhenNotificationsAreOn() {
        let start = Date().addingTimeInterval(-600)
        calendarSource.meetingsToReturn = [
            Meeting(id: "m1", title: "회의", start: start, end: start.addingTimeInterval(1800))
        ]
        // 실제 녹음기와 마이크 권한을 건드리지 않도록 녹음이 시작된 상태만 흉내 낸다.
        delegate.coordinator.onStart = { [weak delegate] _ in delegate?.state = .recording }
        delegate.perform(#selector(AppDelegate.toggleAutoForTesting))
        delegate.perform(#selector(AppDelegate.toggleNotificationsForTesting))
        XCTAssertEqual(delegate.coordinator.autoMeetingId, "m1")
        XCTAssertNil(delegate.meetingNotifier.pendingPrompt)

        // 캘린더에서 회의를 앞당겨 끝낸 것처럼 종료 시각을 지금 이전으로 바꾼다.
        let ended = Meeting(id: "m1", title: "회의", start: start, end: start.addingTimeInterval(300))
        calendarSource.meetingsToReturn = [ended]
        calendarSource.onChange?()

        XCTAssertEqual(delegate.meetingNotifier.pendingPrompt, .end(ended))
        XCTAssertEqual(delegate.state, .recording)
        XCTAssertNil(delegate.coordinator.autoMeetingId)
    }

    /// 알림이 꺼져 있으면 예전처럼 자동이 회의 끝에 녹음을 멈춘다.
    func testAutoRecordingEndStopsWhenNotificationsAreOff() {
        let start = Date().addingTimeInterval(-600)
        calendarSource.meetingsToReturn = [
            Meeting(id: "m1", title: "회의", start: start, end: start.addingTimeInterval(1800))
        ]
        delegate.coordinator.onStart = { [weak delegate] _ in delegate?.state = .recording }
        delegate.perform(#selector(AppDelegate.toggleAutoForTesting))
        XCTAssertEqual(delegate.state, .recording)

        calendarSource.meetingsToReturn = [
            Meeting(id: "m1", title: "회의", start: start, end: start.addingTimeInterval(300))
        ]
        calendarSource.onChange?()

        XCTAssertEqual(delegate.state, .idle)
        XCTAssertNil(delegate.meetingNotifier.pendingPrompt)
    }

    // MARK: - 로그인 시 실행

    /// 로그인 항목은 시스템 설정이라 사용자가 켜기 전에는 등록하지 않는다.
    func testLaunchAtLoginIsOffByDefault() {
        XCTAssertEqual(delegate.launchAtLoginItem.title, "로그인 시 실행")
        XCTAssertEqual(delegate.launchAtLoginItem.state, .off)
        XCTAssertEqual(launchAtLogin.registerCount, 0)
        XCTAssertEqual(launchAtLogin.unregisterCount, 0)
    }

    func testTogglingLaunchAtLoginRegisters() {
        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))

        XCTAssertEqual(launchAtLogin.registerCount, 1)
        XCTAssertEqual(delegate.launchAtLoginItem.state, .on)
        XCTAssertNil(delegate.launchAtLoginItem.toolTip)
        XCTAssertEqual(launchAtLogin.openSystemSettingsCount, 0)
    }

    func testTogglingLaunchAtLoginAgainUnregisters() {
        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))
        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))

        XCTAssertEqual(launchAtLogin.unregisterCount, 1)
        XCTAssertEqual(delegate.launchAtLoginItem.state, .off)
    }

    /// 허용을 기다리는 동안은 실제로 실행되지 않으니 켜짐과 구분하고, 허용할 곳을 열어 준다.
    func testLaunchAtLoginRequiringApprovalShowsMixedAndOpensSettings() {
        launchAtLogin.statusAfterRegister = .requiresApproval

        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))

        XCTAssertEqual(delegate.launchAtLoginItem.state, .mixed)
        XCTAssertEqual(
            delegate.launchAtLoginItem.toolTip,
            "시스템 설정 > 일반 > 로그인 항목에서 Wiret을 허용해야 합니다"
        )
        XCTAssertEqual(launchAtLogin.openSystemSettingsCount, 1)
    }

    /// 허용 대기 중에 다시 누르면 끄지 않고 등록을 다시 시도한다. 켜짐일 때만 끈다.
    func testTogglingWhileRequiringApprovalRegistersAgain() {
        launchAtLogin.status = .requiresApproval
        launchAtLogin.statusAfterRegister = .requiresApproval

        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))

        XCTAssertEqual(launchAtLogin.registerCount, 1)
        XCTAssertEqual(launchAtLogin.unregisterCount, 0)
    }

    func testLaunchAtLoginRegisterFailureLeavesItemOff() {
        launchAtLogin.errorToThrow = LaunchAtLoginTestError()

        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))

        XCTAssertEqual(launchAtLogin.registerCount, 1)
        XCTAssertEqual(delegate.launchAtLoginItem.state, .off)
        XCTAssertEqual(launchAtLogin.openSystemSettingsCount, 0)
    }

    func testLaunchAtLoginUnregisterFailureKeepsItemOn() {
        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))
        launchAtLogin.errorToThrow = LaunchAtLoginTestError()

        delegate.perform(#selector(AppDelegate.toggleLaunchAtLoginForTesting))

        XCTAssertEqual(launchAtLogin.unregisterCount, 1)
        XCTAssertEqual(delegate.launchAtLoginItem.state, .on)
    }

    /// 로그인 항목은 시스템 설정에서도 바뀌므로 메뉴를 열 때 실제 상태를 다시 읽어야 한다.
    func testMenuWillOpenPicksUpExternalLaunchAtLoginChange() {
        XCTAssertEqual(delegate.launchAtLoginItem.state, .off)

        launchAtLogin.status = .enabled
        delegate.menuWillOpen(delegate.statusItem.menu!)
        XCTAssertEqual(delegate.launchAtLoginItem.state, .on)

        launchAtLogin.status = .requiresApproval
        delegate.menuWillOpen(delegate.statusItem.menu!)
        XCTAssertEqual(delegate.launchAtLoginItem.state, .mixed)

        launchAtLogin.status = .notFound
        delegate.menuWillOpen(delegate.statusItem.menu!)
        XCTAssertEqual(delegate.launchAtLoginItem.state, .off)
    }

    // MARK: - 캘린더 선택

    private var calendarMenu: NSMenu {
        delegate.calendarItem.submenu!
    }

    private func calendarMenuItem(titled title: String) -> NSMenuItem? {
        calendarMenu.items.first { $0.title == title }
    }

    private func clickCalendarItem(titled title: String) {
        guard let item = calendarMenuItem(titled: title), let action = item.action else {
            return XCTFail("\(title) 항목이 없습니다")
        }
        _ = delegate.perform(action, with: item)
    }

    func testCalendarMenuListsEveryCalendar() {
        XCTAssertEqual(calendarMenu.items.map(\.title), ["자동 (Google 캘린더)", "", "업무", "개인"])
    }

    /// 계정을 골라 두지 않았으면 예전 동작(Google 캘린더)이 켜져 있어야 한다.
    func testAutomaticIsSelectedByDefault() {
        XCTAssertEqual(calendarMenuItem(titled: "자동 (Google 캘린더)")?.state, .on)
        XCTAssertEqual(calendarMenuItem(titled: "업무")?.state, .off)
    }

    func testSelectingCalendarChecksItAndClearsAutomatic() {
        clickCalendarItem(titled: "업무")

        XCTAssertEqual(delegate.selectedCalendarIDs, ["work"])
        XCTAssertEqual(calendarMenuItem(titled: "업무")?.state, .on)
        XCTAssertEqual(calendarMenuItem(titled: "자동 (Google 캘린더)")?.state, .off)
    }

    func testSelectingSeveralCalendarsKeepsBoth() {
        clickCalendarItem(titled: "업무")
        clickCalendarItem(titled: "개인")

        XCTAssertEqual(delegate.selectedCalendarIDs, ["work", "personal"])
    }

    func testClickingSelectedCalendarUnselectsIt() {
        clickCalendarItem(titled: "업무")
        clickCalendarItem(titled: "업무")

        XCTAssertTrue(delegate.selectedCalendarIDs.isEmpty)
        XCTAssertEqual(calendarMenuItem(titled: "자동 (Google 캘린더)")?.state, .on)
    }

    func testChoosingAutomaticClearsSelection() {
        clickCalendarItem(titled: "업무")

        clickCalendarItem(titled: "자동 (Google 캘린더)")

        XCTAssertTrue(delegate.selectedCalendarIDs.isEmpty)
    }

    /// 선택이 캘린더 소스에 전달되지 않으면 메뉴만 바뀌고 실제 녹음 대상은 그대로다.
    func testSelectionIsPushedToTheCalendarSource() {
        clickCalendarItem(titled: "업무")

        XCTAssertEqual(calendarSource.selectedCalendarIDs, ["work"])
    }

    func testSelectionSurvivesRelaunch() {
        clickCalendarItem(titled: "업무")

        let relaunched = AppDelegate(
            defaults: UserDefaults(suiteName: suiteName)!,
            voiceMemosImporter: VoiceMemosImporter(runner: shortcutRunner),
            shortcutInstaller: VoiceMemosShortcutInstaller(installer: shortcutInstaller),
            calendarSource: calendarSource,
            launchAtLogin: launchAtLogin
        )

        XCTAssertEqual(relaunched.selectedCalendarIDs, ["work"])
    }

    /// 캘린더는 계정 추가·삭제로 바뀌므로 메뉴를 열 때 다시 읽어야 한다.
    func testOpeningCalendarMenuRereadsCalendars() {
        calendarSource.availableCalendars.append(
            CalendarInfo(id: "team", title: "팀", sourceTitle: "aston@kakaocorp.com")
        )

        delegate.menuWillOpen(calendarMenu)

        XCTAssertEqual(calendarMenuItem(titled: "팀")?.state, .off)
    }

    func testCalendarMenuShowsPlaceholderWhenNoCalendarsAreReadable() {
        calendarSource.availableCalendars = []

        delegate.menuWillOpen(calendarMenu)

        XCTAssertEqual(calendarMenu.items.map(\.title), ["자동 (Google 캘린더)", "캘린더를 읽을 수 없습니다"])
        XCTAssertFalse(calendarMenu.items[1].isEnabled)
    }

    // MARK: - 오늘의 일정

    /// 자정 근처에 돌려도 흔들리지 않도록 "지금부터"가 아니라 오늘 0시를 기준으로 잡는다.
    private func todayMeeting(id: String, hoursIntoDay: Double) -> Meeting {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(hoursIntoDay * 3600)
        return Meeting(id: id, title: id, start: start, end: start.addingTimeInterval(1800))
    }

    private var todayMenu: NSMenu {
        delegate.todayScheduleItem.submenu!
    }

    /// 하위 메뉴를 여는 것처럼 회의 목록을 다시 읽게 한다.
    private func openTodayMenu() {
        delegate.menuWillOpen(todayMenu)
    }

    private func clickTodayItem(at index: Int) {
        guard let view = todayMenu.items[index].view as? MenuActionItemView else {
            return XCTFail("\(index)번째 항목이 누를 수 있는 뷰가 아닙니다")
        }
        view.performClick()
    }

    private func todayCheckmarks() -> [Bool?] {
        todayMenu.items.map { ($0.view as? MenuActionItemView)?.isChecked }
    }

    /// 화살표가 붙은 하위 메뉴여야 한다. 직접 단 action이 남아 있으면 누를 때 하위 메뉴 대신 그 일을 한다.
    /// 하위 메뉴를 달면 AppKit이 action을 `submenuAction(_:)`으로 채우므로 그것만 남아 있어야 한다.
    func testTodayScheduleIsSubmenuWithoutAction() {
        XCTAssertNotNil(delegate.todayScheduleItem.submenu)
        XCTAssertEqual(delegate.todayScheduleItem.action, #selector(NSMenu.submenuAction(_:)))
        XCTAssertFalse(delegate.todayScheduleItem.target === delegate)
        XCTAssertFalse(todayMenu.autoenablesItems)
        XCTAssertTrue(todayMenu.delegate === delegate)
    }

    func testTodayMenuListsTodaysMeetingsInOrderAboveRefresh() {
        calendarSource.meetingsToReturn = [
            todayMeeting(id: "m2", hoursIntoDay: 11),
            todayMeeting(id: "m1", hoursIntoDay: 9)
        ]

        openTodayMenu()

        XCTAssertEqual(todayMenu.items.count, 4)
        XCTAssertEqual(todayMenu.items[0].title, "09:00–09:30   m1")
        XCTAssertEqual(todayMenu.items[1].title, "11:00–11:30   m2")
        XCTAssertEqual((todayMenu.items[0].view as? MenuActionItemView)?.title, "09:00–09:30   m1")
        XCTAssertTrue(todayMenu.items[2].isSeparatorItem)
        XCTAssertEqual(todayMenu.items[3].title, "새로고침")
        // 새로고침도 메뉴를 닫지 않아야 새 목록을 바로 볼 수 있다. 상태가 없는 항목이라 체크 칸은 비운다.
        let refresh = todayMenu.items[3].view as? MenuActionItemView
        XCTAssertNotNil(refresh)
        XCTAssertNil(refresh?.isChecked)
    }

    /// 기본은 모두 포함이므로 처음 열면 전부 체크돼 있어야 한다.
    func testTodayMenuStartsWithEverythingIncluded() {
        calendarSource.meetingsToReturn = [
            todayMeeting(id: "m1", hoursIntoDay: 9),
            todayMeeting(id: "m2", hoursIntoDay: 11)
        ]

        openTodayMenu()

        XCTAssertEqual(todayCheckmarks(), [true, true, nil, nil])
        XCTAssertEqual(todayMenu.items[0].state, .on)
    }

    /// 누르면 그 회의만 자동 녹음·알림에서 빠지고, 목록은 그대로 남아 이어서 누를 수 있어야 한다.
    func testClickingMeetingExcludesItInPlace() {
        calendarSource.meetingsToReturn = [
            todayMeeting(id: "m1", hoursIntoDay: 9),
            todayMeeting(id: "m2", hoursIntoDay: 11)
        ]
        openTodayMenu()
        let itemsBefore = todayMenu.items

        clickTodayItem(at: 1)

        XCTAssertEqual(todayCheckmarks(), [true, false, nil, nil])
        XCTAssertEqual(todayMenu.items[1].state, .off)
        XCTAssertEqual(delegate.coordinator.excludedMeetingIdsProvider?(), ["m2"])
        XCTAssertEqual(delegate.meetingNotifier.excludedMeetingIdsProvider?(), ["m2"])
        XCTAssertEqual(todayMenu.items.count, itemsBefore.count)
        XCTAssertTrue(zip(todayMenu.items, itemsBefore).allSatisfy { $0 === $1 })
    }

    /// 뺀 회의는 메뉴를 다시 열어도 꺼진 채여야 한다.
    func testExcludedMeetingStaysUncheckedAfterReopening() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        openTodayMenu()
        clickTodayItem(at: 0)

        openTodayMenu()

        XCTAssertEqual(todayCheckmarks(), [false, nil, nil])
        XCTAssertEqual(todayMenu.items[0].state, .off)
    }

    func testClickingExcludedMeetingIncludesItAgain() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        openTodayMenu()
        clickTodayItem(at: 0)

        clickTodayItem(at: 0)

        XCTAssertEqual(todayCheckmarks(), [true, nil, nil])
        XCTAssertEqual(delegate.coordinator.excludedMeetingIdsProvider?(), [])
    }

    /// 키보드로 고르면 뷰를 거치지 않고 action이 불린다. 이 경로도 같은 회의를 빼야 한다.
    func testMeetingActionTogglesExclusion() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        openTodayMenu()
        let item = todayMenu.items[0]

        _ = delegate.perform(item.action!, with: item)

        XCTAssertEqual(item.state, .off)
        XCTAssertEqual(delegate.coordinator.excludedMeetingIdsProvider?(), ["m1"])
    }

    /// 새로고침은 메뉴를 연 채로 캘린더를 다시 읽어, 그사이 생긴 회의를 보여 줘야 한다.
    func testRefreshPicksUpNewMeetings() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        openTodayMenu()
        let refreshItem = todayMenu.items.last

        calendarSource.meetingsToReturn.append(todayMeeting(id: "m2", hoursIntoDay: 11))
        clickTodayItem(at: todayMenu.items.count - 1)

        XCTAssertEqual(todayMenu.items.map(\.title), ["09:00–09:30   m1", "11:00–11:30   m2", "", "새로고침"])
        // 누른 새로고침 항목은 그대로 두어야 클릭을 처리하던 뷰가 메뉴에서 떨어져 나가지 않는다.
        XCTAssertTrue(todayMenu.items.last === refreshItem)
    }

    func testRefreshKeepsExclusions() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        openTodayMenu()
        clickTodayItem(at: 0)

        clickTodayItem(at: todayMenu.items.count - 1)

        XCTAssertEqual(todayCheckmarks(), [false, nil, nil])
    }

    func testTodayMenuShowsPlaceholderWhenThereAreNoMeetings() {
        openTodayMenu()

        XCTAssertEqual(todayMenu.items.map(\.title), ["오늘 회의가 없습니다", "", "새로고침"])
        XCTAssertFalse(todayMenu.items[0].isEnabled)
        XCTAssertNil(todayMenu.items[0].view)
    }

    /// 회의가 모두 사라지면 이전 회의 줄 대신 안내 문구만 남아야 한다.
    func testRefreshReplacesMeetingsWithPlaceholderWhenTheyAreGone() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        openTodayMenu()

        calendarSource.meetingsToReturn = []
        clickTodayItem(at: todayMenu.items.count - 1)

        XCTAssertEqual(todayMenu.items.map(\.title), ["오늘 회의가 없습니다", "", "새로고침"])
    }

    /// 내일 일정까지 섞여 보이면 오늘 목록이 아니다.
    func testTodayMenuExcludesOtherDays() {
        calendarSource.meetingsToReturn = [
            todayMeeting(id: "today", hoursIntoDay: 9),
            todayMeeting(id: "tomorrow", hoursIntoDay: 33)
        ]

        openTodayMenu()

        XCTAssertEqual(todayMenu.items.map(\.title), ["09:00–09:30   today", "", "새로고침"])
    }
}
