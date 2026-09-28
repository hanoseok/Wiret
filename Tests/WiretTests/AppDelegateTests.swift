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

private final class StubMeetingSource: MeetingSource {
    var onChange: (() -> Void)?
    var availableCalendars: [CalendarInfo] = []
    var selectedCalendarIDs: Set<String> = []

    var meetingsToReturn: [Meeting] = []

    func requestAccess(completion: @escaping (Bool) -> Void) { completion(true) }
    func meetings(from: Date, to: Date) -> [Meeting] { meetingsToReturn }
}

final class AppDelegateTests: XCTestCase {
    private let suiteName = "WiretAppDelegateTests"
    private var delegate: AppDelegate!
    private var shortcutRunner: StubShortcutRunner!
    private var shortcutInstaller: StubShortcutInstaller!
    private var calendarSource: StubMeetingSource!

    override func setUp() {
        super.setUp()
        setenv("WIRET_SUPPRESS_HIDDEN_ALERT", "1", 1)
        let testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
        _ = NSApplication.shared
        shortcutRunner = StubShortcutRunner()
        shortcutInstaller = StubShortcutInstaller()
        calendarSource = StubMeetingSource()
        calendarSource.availableCalendars = [
            CalendarInfo(id: "work", title: "업무", sourceTitle: "aston@kakaocorp.com"),
            CalendarInfo(id: "personal", title: "개인", sourceTitle: "aston@gmail.com")
        ]
        delegate = AppDelegate(
            defaults: testDefaults,
            voiceMemosImporter: VoiceMemosImporter(runner: shortcutRunner),
            shortcutInstaller: VoiceMemosShortcutInstaller(installer: shortcutInstaller),
            calendarSource: calendarSource
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
        delegate = nil
        super.tearDown()
    }

    func testMenuHasExpectedItems() {
        guard let menu = delegate.statusItem.menu else {
            XCTFail("menu missing")
            return
        }
        XCTAssertEqual(menu.items.count, 14)
        XCTAssertEqual(menu.items[0].title, "녹음 시작")
        XCTAssertEqual(menu.items[1].title, "녹음 중단")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].title, "자동")
        XCTAssertEqual(menu.items[4].title, "알림")
        XCTAssertFalse(menu.items[5].isEnabled)
        XCTAssertEqual(menu.items[6].title, "캘린더")
        XCTAssertNotNil(menu.items[6].submenu)
        XCTAssertEqual(menu.items[7].title, "오늘의 일정")
        XCTAssertEqual(menu.items[8].title, "업데이트 확인")
        XCTAssertEqual(menu.items[9].title, delegate.versionItem.title)
        XCTAssertFalse(menu.items[9].isEnabled)
        XCTAssertEqual(menu.items[10].title, "음성 메모로 보내기")
        XCTAssertEqual(menu.items[11].title, "음성 메모 단축어 삭제")
        XCTAssertTrue(menu.items[12].isSeparatorItem)
        XCTAssertEqual(menu.items[13].title, "종료")
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
            calendarSource: calendarSource
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
            calendarSource: calendarSource
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

    func testTodayScheduleWindowListsTodaysMeetings() {
        calendarSource.meetingsToReturn = [
            todayMeeting(id: "m1", hoursIntoDay: 9),
            todayMeeting(id: "m2", hoursIntoDay: 11)
        ]

        delegate.showTodaySchedule()

        XCTAssertEqual(delegate.todayScheduleWindow?.checkboxes.count, 2)
    }

    /// 기본은 모두 포함이므로 처음 열면 전부 체크돼 있어야 한다.
    func testTodayScheduleStartsWithEverythingIncluded() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]

        delegate.showTodaySchedule()

        XCTAssertEqual(delegate.todayScheduleWindow?.checkboxes.first?.state, .on)
    }

    /// 체크를 끄면 그 회의가 자동 녹음 대상에서 빠지고, 창을 다시 열어도 유지돼야 한다.
    func testUncheckingExcludesMeetingAndPersists() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        delegate.showTodaySchedule()

        delegate.todayScheduleWindow?.toggleCheckbox(at: 0)
        delegate.showTodaySchedule()

        XCTAssertEqual(delegate.todayScheduleWindow?.checkboxes.first?.state, .off)
    }

    func testRecheckingIncludesMeetingAgain() {
        calendarSource.meetingsToReturn = [todayMeeting(id: "m1", hoursIntoDay: 9)]
        delegate.showTodaySchedule()
        delegate.todayScheduleWindow?.toggleCheckbox(at: 0)

        delegate.showTodaySchedule()
        delegate.todayScheduleWindow?.toggleCheckbox(at: 0)
        delegate.showTodaySchedule()

        XCTAssertEqual(delegate.todayScheduleWindow?.checkboxes.first?.state, .on)
    }

    /// 내일 일정까지 섞여 보이면 오늘 화면이 아니다.
    func testTodayScheduleExcludesOtherDays() {
        calendarSource.meetingsToReturn = [
            todayMeeting(id: "today", hoursIntoDay: 9),
            todayMeeting(id: "tomorrow", hoursIntoDay: 33)
        ]

        delegate.showTodaySchedule()

        XCTAssertEqual(delegate.todayScheduleWindow?.checkboxes.count, 1)
    }
}
