import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let recorder = AudioRecorder()
    private let calendarSource: MeetingSource
    private let externalRecordingDetector: ExternalRecordingDetecting
    private let defaults: UserDefaults
    private let voiceMemosImporter: VoiceMemosImporter
    private let shortcutInstaller: VoiceMemosShortcutInstaller
    private let launchAtLogin: LaunchAtLoginControlling
    private(set) lazy var coordinator = AutoRecordingCoordinator(source: calendarSource, defaults: defaults)
    private(set) lazy var meetingNotifier = MeetingNotificationCoordinator(source: calendarSource, defaults: defaults)

    var state: RecordingState = .idle {
        didSet { updateMenu() }
    }

    private(set) var statusItem: NSStatusItem!
    private(set) var startItem: NSMenuItem!
    private(set) var stopItem: NSMenuItem!
    private(set) var autoItem: NSMenuItem!
    private(set) var notificationItem: NSMenuItem!
    private(set) var launchAtLoginItem: NSMenuItem!
    private(set) var autoStatusItem: NSMenuItem!
    private(set) var calendarItem: NSMenuItem!
    private(set) var todayScheduleItem: NSMenuItem!
    private(set) var updateItem: NSMenuItem!
    /// 새 버전이 있을 때만 메뉴에 들어간다. 없을 때는 nil이다.
    private(set) var updateAvailableItem: NSMenuItem?
    private(set) var versionItem: NSMenuItem!
    private(set) var voiceMemosItem: NSMenuItem!
    private(set) var shortcutItem: NSMenuItem!

    /// A start request that never completes (a permission prompt left open, say) must not block auto
    /// recording forever.
    private static let startInFlightTimeout: TimeInterval = 120

    private var isStarting = false {
        didSet {
            if isStarting { startRequestedAt = Date() }
        }
    }
    private var startRequestedAt = Date.distantPast
    private var choiceWindow: MeetingChoiceWindowController?
    private var notificationWindow: MeetingNotificationWindowController?
    private lazy var exclusionStore = MeetingExclusionStore(defaults: defaults)
    private let updateCoordinator: UpdateCoordinator
    private var updateTimer: Timer?
    private var updateItemView: MenuActionItemView!
    private var updateCheckStatus: UpdateCheckStatus = .idle {
        didSet { refreshUpdateItem() }
    }
    /// 업데이트 버튼이 가리키는 버전.
    private var availableRelease: ReleaseInfo?
    private var isInstallingUpdate = false {
        didSet { refreshUpdateAvailableItem() }
    }

    /// 자동 업데이트 확인 주기. 하루 종일 켜 두는 메뉴바 앱이라 너무 잦으면 API 호출만 낭비된다.
    private static let updateCheckInterval: TimeInterval = 6 * 3600
    private var wakeObserver: NSObjectProtocol?
    var suppressAlertsForTesting = false

    init(
        defaults: UserDefaults = .standard,
        voiceMemosImporter: VoiceMemosImporter = VoiceMemosImporter(),
        shortcutInstaller: VoiceMemosShortcutInstaller = VoiceMemosShortcutInstaller(),
        calendarSource: MeetingSource = EventKitMeetingSource(),
        externalRecordingDetector: ExternalRecordingDetecting = CoreAudioRecordingDetector(),
        launchAtLogin: LaunchAtLoginControlling = SystemLaunchAtLogin(),
        updateCoordinator: UpdateCoordinator = UpdateCoordinator(
            currentVersion: BundleVersion.current(),
            checker: GitHubUpdateChecker(),
            bundleURL: Bundle.main.bundleURL
        )
    ) {
        self.updateCoordinator = updateCoordinator
        self.defaults = defaults
        self.calendarSource = calendarSource
        self.externalRecordingDetector = externalRecordingDetector
        self.voiceMemosImporter = voiceMemosImporter
        self.shortcutInstaller = shortcutInstaller
        self.launchAtLogin = launchAtLogin
        super.init()
    }

    private static let voiceMemosImportKey = "voiceMemosImportEnabled"
    private static let selectedCalendarsKey = "selectedCalendarIDs"

    /// 사용자가 고른 캘린더 식별자. 비어 있으면 자동(Google 우선)으로 동작한다.
    var selectedCalendarIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.selectedCalendarsKey) ?? []) }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Self.selectedCalendarsKey)
            calendarSource.selectedCalendarIDs = newValue
        }
    }

    /// 음성 메모 가져오기는 사용자가 단축어를 만들어 두어야 동작하므로 기본값은 꺼짐이다.
    var isVoiceMemosImportEnabled: Bool {
        get { defaults.bool(forKey: Self.voiceMemosImportKey) }
        set { defaults.set(newValue, forKey: Self.voiceMemosImportKey) }
    }

    /// 녹음이 예기치 않게 끝났을 때도 가져올 파일을 알 수 있도록 현재 녹음 경로를 들고 있는다.
    private var currentRecordingURL: URL?

    deinit {
        updateTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        startItem = NSMenuItem(title: "녹음 시작", action: #selector(startRecording), keyEquivalent: "r")
        startItem.target = self
        menu.addItem(startItem)

        stopItem = NSMenuItem(title: "녹음 중단", action: #selector(stopRecording), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        autoItem = NSMenuItem(title: "자동", action: #selector(toggleAuto), keyEquivalent: "")
        autoItem.target = self
        menu.addItem(autoItem)

        notificationItem = NSMenuItem(title: "알림", action: #selector(toggleNotifications), keyEquivalent: "")
        notificationItem.target = self
        menu.addItem(notificationItem)

        // 자동·알림처럼 앱 전체에 걸리는 켜기/끄기 설정이라 그 바로 아래에 둔다.
        launchAtLoginItem = NSMenuItem(
            title: "로그인 시 실행",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        refreshLaunchAtLoginItem()

        autoStatusItem = NSMenuItem(title: "자동: 꺼짐", action: nil, keyEquivalent: "")
        autoStatusItem.isEnabled = false
        menu.addItem(autoStatusItem)

        calendarItem = NSMenuItem(title: "캘린더", action: nil, keyEquivalent: "")
        let calendarMenu = NSMenu()
        calendarMenu.autoenablesItems = false
        calendarMenu.delegate = self
        calendarItem.submenu = calendarMenu
        menu.addItem(calendarItem)

        // 회의를 여러 개 연달아 켜고 끄기 쉽도록 창 대신 하위 메뉴로 보여 준다.
        todayScheduleItem = NSMenuItem(title: "오늘의 일정", action: nil, keyEquivalent: "")
        todayScheduleItem.submenu = makeTodayScheduleMenu()
        menu.addItem(todayScheduleItem)

        updateItem = NSMenuItem(
            title: UpdateCheckStatus.idle.title,
            action: #selector(checkForUpdatesManually),
            keyEquivalent: ""
        )
        updateItem.target = self
        // 뷰 안의 클릭은 메뉴를 닫지 않는다. 확인 결과를 메뉴를 연 채로 그 자리에서 보여 주려고 뷰를 쓴다.
        // 키보드로 고르면 뷰를 거치지 않고 위의 action이 불리며, 이때는 메뉴가 닫힌다.
        updateItemView = MenuActionItemView(title: UpdateCheckStatus.idle.title)
        updateItemView.onClick = { [weak self] in self?.checkForUpdatesManually() }
        updateItem.view = updateItemView
        menu.addItem(updateItem)

        versionItem = NSMenuItem(title: Self.versionTitle(for: nil), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        voiceMemosItem = NSMenuItem(
            title: "음성 메모로 보내기",
            action: #selector(toggleVoiceMemosImport),
            keyEquivalent: ""
        )
        voiceMemosItem.target = self
        voiceMemosItem.state = isVoiceMemosImportEnabled ? .on : .off
        menu.addItem(voiceMemosItem)

        shortcutItem = NSMenuItem(
            title: shortcutItemTitle,
            action: #selector(toggleShortcutInstallation),
            keyEquivalent: ""
        )
        shortcutItem.target = self
        menu.addItem(shortcutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // 단축어는 Wiret 밖에서도 추가·삭제되므로 메뉴를 열 때마다 상태를 다시 읽는다.
        menu.delegate = self
        statusItem.menu = menu

        recorder.onUnexpectedStop = { [weak self] error in
            self?.handleUnexpectedStop(error)
        }

        coordinator.isRecordingProvider = { [weak self] in self?.state == .recording }
        coordinator.isStartInFlightProvider = { [weak self] in self?.isStartInFlight ?? false }
        coordinator.isExternalRecordingProvider = { [weak self] in
            self?.externalRecordingDetector.isVoiceMemosRecording ?? false
        }
        coordinator.excludedMeetingIdsProvider = { [weak self] in
            self?.exclusionStore.excludedIDs ?? []
        }
        // 반복 일정은 회차마다 식별자가 달라 제외 기록이 쌓인다. 실행할 때 한 번 정리한다.
        exclusionStore.prune()
        coordinator.onStart = { [weak self] meeting in self?.startAutoRecording(for: meeting) }
        coordinator.onStop = { [weak self] in self?.endRecording() }
        // 알림이 켜져 있으면 회의가 끝나도 바로 멈추지 않고 종료 알림으로 묻는다. 자동은 start()에서야
        // 확인을 시작하고, 알림은 그 전에 configureMeetingNotifier()로 준비된다.
        coordinator.shouldHandOffEndProvider = { [weak self] in self?.meetingNotifier.isEnabled ?? false }
        coordinator.onHandOffEnd = { [weak self] meeting in self?.meetingNotifier.adoptEndedRecording(of: meeting) }
        coordinator.onStatusText = { [weak self] text in self?.autoStatusItem.title = text }
        coordinator.onAccessDenied = { [weak self] in
            self?.showCalendarDeniedAlert()
            self?.autoItem.state = .off
        }
        coordinator.onChoose = { [weak self] meetings in self?.presentMeetingChoice(meetings) }
        coordinator.onChoiceObsolete = { [weak self] in self?.dismissMeetingChoice() }
        autoItem.state = coordinator.isEnabled ? .on : .off
        configureMeetingNotifier()
        // 두 코디네이터가 같은 캘린더를 본다. onChange는 하나뿐이라 여기서 둘 다에 전달한다.
        calendarSource.onChange = { [weak self] in
            self?.coordinator.tick()
            self?.meetingNotifier.tick()
        }
        calendarSource.selectedCalendarIDs = selectedCalendarIDs
        rebuildCalendarMenu()
        coordinator.start()
        meetingNotifier.start()

        // Waking from sleep: re-check immediately so a meeting that ended while asleep stops right
        // away and a meeting that is now in progress starts.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator.tick()
            self?.meetingNotifier.tick()
        }

        updateMenu()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.warnIfStatusItemHidden()
        }

        startUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.releaseForTermination()
        meetingNotifier.releaseForTermination()
        let url = recorder.stop() ?? currentRecordingURL
        currentRecordingURL = nil
        if let url {
            // 프로세스가 곧 사라지므로 백그라운드 큐에 맡기면 가져오기가 중간에 끊긴다.
            importToVoiceMemos(url, synchronously: true)
        }
    }

    var isStatusItemVisibleInMenuBar: Bool {
        guard let window = statusItem?.button?.window else { return false }
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return false }
        return MenuBarVisibility.isItemVisible(
            itemFrame: window.frame,
            rightArea: screen.auxiliaryTopRightArea,
            screenFrame: screen.frame
        )
    }

    private func warnIfStatusItemHidden() {
        if suppressAlertsForTesting { return }
        if isStatusItemVisibleInMenuBar { return }
        if ProcessInfo.processInfo.environment["WIRET_SUPPRESS_HIDDEN_ALERT"] != nil { return }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "메뉴 막대에 공간이 부족해 Wiret 아이콘이 숨겨졌습니다"
        alert.informativeText = "macOS는 메뉴 막대가 가득 차면 새 아이콘을 노치 뒤로 숨깁니다. 다른 메뉴 막대 아이콘을 제거하거나(⌘ 드래그로 메뉴 막대 밖으로 끌어내기), Ice/Bartender 같은 메뉴 막대 관리 앱을 사용하면 Wiret 아이콘이 표시됩니다. Wiret은 계속 실행 중이며 아이콘이 나타나면 바로 사용할 수 있습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "종료")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func updateMenu() {
        guard let startItem, let stopItem else { return }
        let availability = state.menuAvailability
        startItem.isEnabled = availability.canStart
        stopItem.isEnabled = availability.canStop

        if let button = statusItem.button {
            switch state {
            case .idle:
                button.image = MouseIcon.menuBarImage(recording: false)
                button.contentTintColor = nil
            case .recording:
                button.image = MouseIcon.menuBarImage(recording: true)
                button.contentTintColor = .systemRed
            }
        }
    }

    @objc private func startRecording() {
        _ = beginRecording(title: nil)
    }

    private func startAutoRecording(for meeting: Meeting) {
        let accepted = beginRecording(title: meeting.title, onFailure: { [weak self] in
            self?.coordinator.noteAutoStartFailed()
        })
        if !accepted {
            // Busy or already recording: don't leave the coordinator waiting on a recording that never began.
            coordinator.noteAutoStartFailed()
        }
    }

    /// 회의 시작 알림에서 "녹음 시작"을 눌렀을 때.
    private func startNotifiedRecording(for meeting: Meeting) {
        let accepted = beginRecording(title: meeting.title, onFailure: { [weak self] in
            self?.meetingNotifier.noteStartFailed()
        })
        if !accepted {
            meetingNotifier.noteStartFailed()
        }
    }

    /// 시작 요청이 처리되는 중인지. 끝나지 않는 요청(권한 창을 열어 둔 채 방치 등)이 자동 녹음과 알림을
    /// 영영 막지 않도록 일정 시간이 지나면 풀어 준다.
    private var isStartInFlight: Bool {
        guard isStarting else { return false }
        return Date().timeIntervalSince(startRequestedAt) < Self.startInFlightTimeout
    }

    /// - Parameter onFailure: 요청은 받아들였지만 권한이나 녹음기 문제로 시작하지 못했을 때 호출된다.
    ///   시작을 요청한 쪽(자동 녹음 또는 알림)이 기다리던 상태를 풀 수 있도록 넘겨받는다.
    /// - Returns: whether the start request was accepted.
    @discardableResult
    private func beginRecording(title: String?, onFailure: (() -> Void)? = nil) -> Bool {
        guard state == .idle, !isStarting else {
            return false
        }
        isStarting = true
        startItem.isEnabled = false

        recorder.requestPermission { [weak self] granted in
            guard let self else { return }
            self.isStarting = false
            if granted {
                do {
                    self.currentRecordingURL = try self.recorder.start(title: title)
                    self.state = .recording
                    self.meetingNotifier.noteRecordingStarted()
                } catch {
                    self.updateMenu()
                    onFailure?()
                    self.showErrorAlert(error)
                }
            } else {
                self.updateMenu()
                onFailure?()
                self.showPermissionDeniedAlert()
            }
        }
        return true
    }

    @objc private func stopRecording() {
        coordinator.noteManualStop()
        endRecording()
    }

    private func endRecording() {
        let url = recorder.stop() ?? currentRecordingURL
        currentRecordingURL = nil
        state = .idle
        meetingNotifier.noteRecordingStopped()
        if let url {
            importToVoiceMemos(url)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // 캘린더는 계정 추가·삭제로 바뀌므로 열 때마다 다시 읽는다.
        if menu === calendarItem?.submenu {
            rebuildCalendarMenu()
            return
        }
        // 일정은 언제든 바뀌므로 열 때마다 캘린더를 다시 읽는다.
        if menu === todayScheduleItem?.submenu {
            reloadTodayMeetingItems()
            return
        }
        refreshShortcutItem()
        // 로그인 항목은 시스템 설정에서도 켜고 끌 수 있으므로 열 때마다 실제 상태를 다시 읽는다.
        refreshLaunchAtLoginItem()
        // 며칠 전의 "최신 버전입니다"가 남아 있으면 지금도 최신인 것처럼 읽힌다. 확인 중일 때만 그대로 둔다.
        if updateCheckStatus != .checking {
            updateCheckStatus = .idle
        }
    }

    // MARK: - 캘린더 선택

    func rebuildCalendarMenu() {
        guard let menu = calendarItem?.submenu else { return }
        menu.removeAllItems()

        let calendars = calendarSource.availableCalendars
        let selected = selectedCalendarIDs

        let automaticItem = NSMenuItem(
            title: "자동 (Google 캘린더)",
            action: #selector(selectAutomaticCalendars),
            keyEquivalent: ""
        )
        automaticItem.target = self
        automaticItem.state = CalendarSelection.isAutomatic(all: calendars, selected: selected) ? .on : .off
        menu.addItem(automaticItem)

        guard !calendars.isEmpty else {
            let empty = NSMenuItem(title: "캘린더를 읽을 수 없습니다", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        menu.addItem(NSMenuItem.separator())

        for calendar in calendars {
            let item = NSMenuItem(
                title: calendar.title,
                action: #selector(toggleCalendar(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = calendar.id
            item.state = selected.contains(calendar.id) ? .on : .off
            // 이름이 같은 캘린더가 여러 계정에 있을 수 있어 계정을 함께 보여준다.
            item.toolTip = calendar.sourceTitle
            menu.addItem(item)
        }
    }

    @objc private func selectAutomaticCalendars() {
        selectedCalendarIDs = []
        applyCalendarSelectionChange()
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var selection = selectedCalendarIDs
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        selectedCalendarIDs = selection
        applyCalendarSelectionChange()
    }

    private func applyCalendarSelectionChange() {
        rebuildCalendarMenu()
        // 바뀐 선택으로 지금 회의 상태를 다시 판단한다.
        coordinator.tick()
        meetingNotifier.tick()
    }

    // MARK: - 오늘의 일정

    private static let meetingTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 회의 줄 아래에 구분선과 새로고침을 한 번만 만들어 둔다.
    ///
    /// 새로고침을 누른 채로 그 항목을 지우고 다시 만들면 클릭을 처리하던 뷰가 메뉴에서 떨어져 나간다.
    /// 그래서 다시 읽을 때는 구분선 위의 회의 줄만 갈아 끼운다.
    private func makeTodayScheduleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(
            title: "새로고침",
            action: #selector(refreshTodaySchedule),
            keyEquivalent: ""
        )
        refreshItem.target = self
        // 새로 읽은 목록을 메뉴를 연 채로 바로 보여 주려고 뷰를 쓴다. 키보드로 고르면 위의 action이 불리고 메뉴가 닫힌다.
        let refreshView = MenuActionItemView(title: "새로고침")
        refreshView.onClick = { [weak self] in self?.refreshTodaySchedule() }
        refreshItem.view = refreshView
        menu.addItem(refreshItem)
        return menu
    }

    /// 구분선 위의 회의 줄을 캘린더에서 새로 읽은 오늘 회의로 바꾼다.
    func reloadTodayMeetingItems() {
        guard let menu = todayScheduleItem?.submenu else { return }
        while let first = menu.items.first, !first.isSeparatorItem {
            menu.removeItem(first)
        }

        let meetings = todayMeetings()
        guard !meetings.isEmpty else {
            let empty = NSMenuItem(title: "오늘 회의가 없습니다", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.insertItem(empty, at: 0)
            return
        }
        for (index, meeting) in meetings.enumerated() {
            menu.insertItem(makeTodayMeetingItem(meeting), at: index)
        }
    }

    private func todayMeetings() -> [Meeting] {
        let now = Date()
        // 오늘 하루를 넉넉히 덮도록 앞뒤로 여유를 두고 읽는다.
        return TodaySchedule.meetings(
            in: calendarSource.meetings(
                from: now.addingTimeInterval(-24 * 3600),
                to: now.addingTimeInterval(24 * 3600)
            ),
            on: now
        )
    }

    /// 체크된 회의가 자동 녹음·알림 대상이다. 기본은 모두 포함이라 뺀 회의만 체크가 꺼진다.
    ///
    /// 일반 메뉴 항목은 누르면 메뉴가 닫혀 여러 회의를 끄려면 메뉴를 몇 번이고 다시 열어야 한다.
    /// 뷰 안의 클릭은 메뉴를 닫지 않으므로 뷰를 단다.
    private func makeTodayMeetingItem(_ meeting: Meeting) -> NSMenuItem {
        let time = "\(Self.meetingTimeFormatter.string(from: meeting.start))–\(Self.meetingTimeFormatter.string(from: meeting.end))"
        let title = "\(time)   \(meeting.title)"

        let item = NSMenuItem(title: title, action: #selector(toggleTodayMeeting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = meeting
        let view = MenuActionItemView(title: title)
        view.onClick = { [weak self, weak item] in
            guard let item else { return }
            self?.toggleTodayMeeting(item)
        }
        item.view = view
        applyTodayMeetingState(to: item, meeting: meeting)
        return item
    }

    /// 그려지는 체크마크와 `NSMenuItem.state`를 함께 맞춘다. 키보드 탐색과 테스트는 state를 본다.
    private func applyTodayMeetingState(to item: NSMenuItem, meeting: Meeting) {
        let included = !exclusionStore.isExcluded(meeting)
        item.state = included ? .on : .off
        (item.view as? MenuActionItemView)?.isChecked = included
    }

    @objc private func toggleTodayMeeting(_ sender: NSMenuItem) {
        guard let meeting = sender.representedObject as? Meeting else { return }
        exclusionStore.setExcluded(!exclusionStore.isExcluded(meeting), meeting: meeting)
        // 누른 줄의 뷰가 아직 클릭을 처리하는 중이라 목록을 다시 만들지 않고 그 줄만 바꾼다.
        applyTodayMeetingState(to: sender, meeting: meeting)
        // 지금 녹음 중인 회의를 뺐다면 곧바로 반영되어야 한다.
        coordinator.tick()
        meetingNotifier.tick()
    }

    @objc private func refreshTodaySchedule() {
        reloadTodayMeetingItems()
    }

    /// 단축어가 이미 있으면 삭제를, 없으면 설치를 제안한다. 둘 중 하나만 보인다.
    var shortcutItemTitle: String {
        voiceMemosImporter.isShortcutInstalled ? "음성 메모 단축어 삭제" : "음성 메모 단축어 설치"
    }

    func refreshShortcutItem() {
        shortcutItem?.title = shortcutItemTitle
    }

    @objc private func toggleShortcutInstallation() {
        if voiceMemosImporter.isShortcutInstalled {
            requestShortcutRemoval()
        } else {
            installShortcut()
        }
        refreshShortcutItem()
    }

    @discardableResult
    func installShortcut() -> Bool {
        switch shortcutInstaller.install() {
        case .success:
            showShortcutInstallAlert()
            return true
        case .failure(let error):
            showShortcutErrorAlert(error)
            return false
        }
    }

    private func requestShortcutRemoval() {
        // macOS는 앱이 단축어를 직접 지우는 것을 허용하지 않는다. 단축어 앱에서 열어주는 것까지가 한계다.
        shortcutInstaller.openForRemoval()
        showShortcutRemovalAlert()
    }

    /// 테스트에서 메뉴 동작을 그대로 호출하기 위한 통로.
    @objc func toggleAutoForTesting() {
        toggleAuto()
    }

    @objc private func toggleAuto() {
        let willEnable = !coordinator.isEnabled

        // 자동 녹음을 켜는 시점에는 음성 메모 단축어가 준비돼 있어야 한다. 없으면 바로 설치를 띄운다.
        if willEnable, !voiceMemosImporter.isShortcutInstalled {
            installShortcut()
        }

        coordinator.setEnabled(willEnable)
        autoItem.state = coordinator.isEnabled ? .on : .off
        refreshShortcutItem()
        // 자동이 켜지면 떠 있던 시작 알림은 필요 없고, 꺼지면 알림이 회의 시작을 맡는다.
        meetingNotifier.tick()
    }

    // MARK: - 회의 알림

    /// 테스트에서 메뉴 동작을 그대로 호출하기 위한 통로.
    @objc func toggleNotificationsForTesting() {
        toggleNotifications()
    }

    @objc private func toggleNotifications() {
        meetingNotifier.setEnabled(!meetingNotifier.isEnabled)
        notificationItem.state = meetingNotifier.isEnabled ? .on : .off
    }

    // MARK: - 로그인 시 실행

    /// 테스트에서 메뉴 동작을 그대로 호출하기 위한 통로.
    @objc func toggleLaunchAtLoginForTesting() {
        toggleLaunchAtLogin()
    }

    /// 실행할 때 저절로 등록하지는 않는다. 로그인 항목은 시스템 설정이라 사용자가 메뉴에서 직접 고르게 한다.
    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLogin.status == .enabled {
                try launchAtLogin.unregister()
            } else {
                try launchAtLogin.register()
                // 관리 정책이나 사용자 설정에 따라 등록만 되고 허용을 기다릴 수 있다. 허용할 곳을 바로 열어 준다.
                if launchAtLogin.status == .requiresApproval {
                    launchAtLogin.openSystemSettings()
                    showLaunchAtLoginApprovalAlert()
                }
            }
        } catch {
            showLaunchAtLoginErrorAlert(error)
        }
        refreshLaunchAtLoginItem()
    }

    private static let launchAtLoginApprovalTip = "시스템 설정 > 일반 > 로그인 항목에서 Wiret을 허용해야 합니다"

    func refreshLaunchAtLoginItem() {
        guard let launchAtLoginItem else { return }
        switch launchAtLogin.status {
        case .enabled:
            launchAtLoginItem.state = .on
            launchAtLoginItem.toolTip = nil
        case .requiresApproval:
            // 등록은 됐지만 아직 실행되지 않는 상태라 켜짐과 구분해 보여 준다.
            launchAtLoginItem.state = .mixed
            launchAtLoginItem.toolTip = Self.launchAtLoginApprovalTip
        case .notRegistered, .notFound:
            launchAtLoginItem.state = .off
            launchAtLoginItem.toolTip = nil
        }
    }

    private func configureMeetingNotifier() {
        meetingNotifier.isRecordingProvider = { [weak self] in self?.state == .recording }
        meetingNotifier.isStartInFlightProvider = { [weak self] in self?.isStartInFlight ?? false }
        meetingNotifier.isAutoEnabledProvider = { [weak self] in self?.coordinator.isEnabled ?? false }
        meetingNotifier.isAutoRecordingProvider = { [weak self] in self?.coordinator.autoMeetingId != nil }
        meetingNotifier.isExternalRecordingProvider = { [weak self] in
            self?.externalRecordingDetector.isVoiceMemosRecording ?? false
        }
        meetingNotifier.excludedMeetingIdsProvider = { [weak self] in
            self?.exclusionStore.excludedIDs ?? []
        }
        meetingNotifier.onStart = { [weak self] meeting in self?.startNotifiedRecording(for: meeting) }
        meetingNotifier.onStop = { [weak self] in
            // 메뉴에서 중단한 것과 같다. 자동 녹음이 같은 회의를 다시 시작하지 않게 한다.
            self?.coordinator.noteManualStop()
            self?.endRecording()
        }
        meetingNotifier.onPrompt = { [weak self] prompt in self?.presentMeetingNotification(prompt) }
        meetingNotifier.onPromptObsolete = { [weak self] in self?.dismissMeetingNotification() }
        meetingNotifier.onAccessDenied = { [weak self] in
            self?.showCalendarDeniedAlert()
            self?.notificationItem.state = .off
        }
        notificationItem.state = meetingNotifier.isEnabled ? .on : .off
    }

    private func presentMeetingNotification(_ prompt: MeetingNotificationPrompt) {
        dismissMeetingNotification()
        if suppressAlertsForTesting { return }

        // 응답은 창이 닫힌 뒤 비동기로 넘어온다. 그사이 새 알림 창으로 바뀌었다면 지난 창의 답은 버린다.
        weak var weakController: MeetingNotificationWindowController?
        let controller = MeetingNotificationWindowController(prompt: prompt) { [weak self] response in
            guard let self, let responder = weakController, responder === self.notificationWindow else { return }
            self.notificationWindow = nil
            self.meetingNotifier.respond(response, to: responder.prompt)
        }
        weakController = controller
        notificationWindow = controller
        controller.show()
    }

    private func dismissMeetingNotification() {
        notificationWindow?.dismiss()
        notificationWindow = nil
    }

    @objc private func toggleVoiceMemosImport() {
        if isVoiceMemosImportEnabled {
            setVoiceMemosImport(enabled: false)
            return
        }

        // 단축어가 없으면 녹음이 끝날 때마다 실패한다. 켜는 시점에 바로 단축어를 만들어 주고,
        // 사용자가 단축어 앱에서 추가를 끝낼 때까지는 켜지 않는다. "켜짐"이 곧 "동작함"이어야 한다.
        guard voiceMemosImporter.isShortcutInstalled else {
            setVoiceMemosImport(enabled: false)
            installShortcut()
            refreshShortcutItem()
            return
        }
        setVoiceMemosImport(enabled: true)
    }

    private func setVoiceMemosImport(enabled: Bool) {
        isVoiceMemosImportEnabled = enabled
        voiceMemosItem?.state = enabled ? .on : .off
    }

    /// 녹음을 음성 메모로 가져온다. 원본 삭제는 가져오기가 성공했을 때만 일어난다.
    private func importToVoiceMemos(_ url: URL, synchronously: Bool = false) {
        guard isVoiceMemosImportEnabled else { return }

        let importer = voiceMemosImporter
        let work = { [weak self] in
            let result = importer.importRecording(at: url, deletingOriginal: true)
            guard case .failure(let error) = result else { return }
            let report: () -> Void = {
                guard let self else { return }
                self.handleVoiceMemosImportFailure(error)
            }
            if synchronously {
                report()
            } else {
                DispatchQueue.main.async(execute: report)
            }
        }

        if synchronously {
            work()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }

    func handleVoiceMemosImportFailure(_ error: VoiceMemosImportError) {
        // 빈 녹음은 애초에 가져올 게 없으므로 조용히 넘어간다.
        if case .recordingUnavailable = error { return }

        // 단축어가 사라진 상태로 두면 녹음이 끝날 때마다 같은 실패가 반복된다.
        if case .shortcutMissing = error {
            setVoiceMemosImport(enabled: false)
        }
        showVoiceMemosErrorAlert(error)
    }

    @objc private func quit() {
        if recorder.hasActiveRecorder {
            _ = recorder.stop()
        }
        NSApp.terminate(nil)
    }

    func handleUnexpectedStop(_ error: Error?) {
        coordinator.noteManualStop()
        state = .idle
        meetingNotifier.noteRecordingStopped()
        let url = currentRecordingURL
        currentRecordingURL = nil
        if let url {
            importToVoiceMemos(url)
        }
        if let error {
            showErrorAlert(error)
        }
    }

    // MARK: - 자동 업데이트

    /// 메뉴에 보여줄 버전 문구. 로컬 빌드는 채널을 몰라 업데이트를 확인하지 않는다는 것을 그대로 드러낸다.
    static func versionTitle(for version: AppVersion?) -> String {
        guard let version else {
            return "현재 버전: 로컬 빌드 (자동 업데이트 꺼짐)"
        }
        return "현재 버전: \(version)"
    }

    /// 로컬 빌드는 WiretVersion이 없어 채널을 알 수 없으므로 왜 업데이트 확인이 꺼져 있는지 알려 준다.
    private static let localBuildTip =
        "WiretVersion이 없는 로컬 빌드라 채널을 몰라 업데이트를 확인하지 않습니다. 릴리스나 스냅샷 zip을 /Applications에 설치하면 자동 업데이트를 받을 수 있습니다."

    private func startUpdateChecks() {
        let version = updateCoordinator.currentVersion
        versionItem?.title = Self.versionTitle(for: version)
        versionItem?.toolTip = version == nil ? Self.localBuildTip : nil
        refreshUpdateItem()

        updateCoordinator.isBusyProvider = { [weak self] in
            // 녹음 중에는 끼어들지 않는다. 앱을 교체하면 녹음이 끊긴다.
            self?.state == .recording
        }
        // 콜백은 백그라운드 큐에서 온다. 메인 큐는 메뉴가 열려 있는 동안에도 돌므로 열린 메뉴가 그대로 바뀐다.
        updateCoordinator.onUpdateAvailable = { [weak self] release, userInitiated in
            DispatchQueue.main.async { self?.handleUpdateAvailable(release, userInitiated: userInitiated) }
        }
        updateCoordinator.onUpToDate = { [weak self] _ in
            DispatchQueue.main.async { self?.updateCheckStatus = .upToDate }
        }
        updateCoordinator.onCheckFailed = { [weak self] error in
            DispatchQueue.main.async { self?.updateCheckStatus = .failed(error) }
        }
        updateCoordinator.onInstalled = { [weak self] release in
            DispatchQueue.main.async { self?.finishUpdate(release) }
        }
        updateCoordinator.onError = { [weak self] error in
            DispatchQueue.main.async {
                // 다시 누를 수 있게 버튼을 되돌린다. 실패 이유는 메뉴 한 줄에 담기 어려워 창으로 알린다.
                self?.isInstallingUpdate = false
                self?.showUpdateErrorAlert(error)
            }
        }

        guard updateCoordinator.canCheck else { return }

        updateCoordinator.check(userInitiated: false)
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: Self.updateCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.updateCoordinator.check(userInitiated: false)
        }
    }

    @objc private func checkForUpdatesManually() {
        guard updateCoordinator.canCheck, updateCheckStatus != .checking else { return }
        updateCheckStatus = .checking
        updateCoordinator.check(userInitiated: true)
    }

    private func handleUpdateAvailable(_ release: ReleaseInfo, userInitiated: Bool) {
        // 내려받는 중에 버튼을 바꾸면 진행 중인 설치와 다른 버전을 가리키게 된다. 묻는 창도 띄우지 않는다.
        guard !isInstallingUpdate else { return }
        if userInitiated {
            // 결과는 바로 아래에 생긴 버튼이 말해 주므로 확인 항목은 원래 문구로 돌아간다.
            updateCheckStatus = .idle
        }
        showUpdateButton(for: release)
        if !userInitiated {
            // 메뉴를 열지 않는 사용자도 있으니 자동 확인은 지금까지처럼 창으로도 묻는다.
            presentUpdatePrompt(release)
        }
    }

    /// 새 버전이 있을 때만 "업데이트 확인" 바로 아래에 버튼을 둔다. 더 새 버전이 나오면 같은 버튼을 고쳐 쓴다.
    private func showUpdateButton(for release: ReleaseInfo) {
        availableRelease = release
        if updateAvailableItem == nil, let menu = updateItem.menu {
            let item = NSMenuItem(title: "", action: #selector(installAvailableUpdate), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: menu.index(of: updateItem) + 1)
            updateAvailableItem = item
        }
        refreshUpdateAvailableItem()
    }

    /// 버튼은 일반 메뉴 항목이라 누르면 메뉴가 닫힌다. 내려받기는 기다려야 하는 일이라 그편이 자연스럽다.
    @objc private func installAvailableUpdate() {
        guard let availableRelease else { return }
        installUpdate(availableRelease)
    }

    /// 버튼과 자동 확인 창의 "지금 업데이트"가 같은 길을 타야 버튼 상태가 어긋나지 않는다.
    private func installUpdate(_ release: ReleaseInfo) {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateCoordinator.install(release)
    }

    private func refreshUpdateItem() {
        guard let updateItem, let updateItemView else { return }
        let canCheck = updateCoordinator.canCheck
        let status = updateCheckStatus
        let isEnabled = canCheck && status != .checking
        let toolTip: String?
        if !canCheck {
            toolTip = Self.localBuildTip
        } else if case .failed(let error) = status {
            toolTip = error.errorDescription
        } else {
            toolTip = nil
        }

        // 테스트와 손쉬운 사용은 메뉴 항목의 제목을 읽으므로 뷰와 항목을 함께 맞춘다.
        updateItemView.title = status.title
        updateItemView.isEnabled = isEnabled
        updateItemView.toolTip = toolTip
        updateItem.title = status.title
        updateItem.isEnabled = isEnabled
        updateItem.toolTip = toolTip
    }

    private func refreshUpdateAvailableItem() {
        guard let updateAvailableItem, let availableRelease else { return }
        updateAvailableItem.title = isInstallingUpdate
            ? "업데이트 내려받는 중…"
            : "\(availableRelease.version)으로 업데이트"
        updateAvailableItem.isEnabled = !isInstallingUpdate
    }

    private func presentUpdatePrompt(_ release: ReleaseInfo) {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "새 버전 \(release.version)이 있습니다"
        alert.informativeText = "지금 업데이트하면 Wiret을 내려받아 교체한 뒤 다시 실행합니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "지금 업데이트")
        alert.addButton(withTitle: "나중에")
        if release.pageURL != nil {
            alert.addButton(withTitle: "변경 내용 보기")
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installUpdate(release)
        case .alertThirdButtonReturn:
            if let page = release.pageURL {
                NSWorkspace.shared.open(page)
            }
            updateCoordinator.postpone(release)
        default:
            updateCoordinator.postpone(release)
        }
    }

    /// 교체가 끝났으니 새 버전으로 다시 실행한다.
    private func finishUpdate(_ release: ReleaseInfo) {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "\(release.version)으로 업데이트했습니다"
        alert.informativeText = "확인을 누르면 Wiret을 다시 실행합니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()

        relaunch()
    }

    private func relaunch() {
        // 이 프로세스가 사라진 뒤에 열려야 하므로, 잠깐 기다렸다 여는 별도 프로세스에 맡긴다.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 경로를 인자로 넘겨 따옴표 문제를 피한다.
        process.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundleURL.path]
        try? process.run()

        NSApp.terminate(nil)
    }

    private func showUpdateErrorAlert(_ error: UpdateError) {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "업데이트하지 못했습니다"
        alert.informativeText = error.errorDescription ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func presentMeetingChoice(_ meetings: [Meeting]) {
        if suppressAlertsForTesting { return }
        dismissMeetingChoice()

        let controller = MeetingChoiceWindowController(
            meetings: meetings,
            onChoose: { [weak self] meeting in
                self?.choiceWindow = nil
                self?.coordinator.choose(meeting)
            },
            onSkip: { [weak self] in
                self?.choiceWindow = nil
                self?.coordinator.skipChoice()
            }
        )
        choiceWindow = controller
        controller.show()
    }

    private func dismissMeetingChoice() {
        choiceWindow?.dismiss()
        choiceWindow = nil
    }

    private func showPermissionDeniedAlert() {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "마이크 접근 권한이 필요합니다"
        alert.informativeText = "시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 Wiret의 접근을 허용해주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "취소")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showCalendarDeniedAlert() {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "캘린더 접근 권한이 필요합니다"
        alert.informativeText = "시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 Wiret를 허용하면 Google 캘린더(macOS 캘린더 앱에 추가된 Google 계정)의 회의에 맞춰 자동으로 녹음합니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "시스템 설정 열기")
        alert.addButton(withTitle: "취소")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showShortcutInstallAlert() {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "단축어 앱에서 추가를 눌러주세요"
        alert.informativeText = """
        \(VoiceMemosImporter.defaultShortcutName) 단축어를 만들어 단축어 앱에 넘겼습니다. 열린 창에서 "단축어 추가"를 누르면 설정이 끝납니다.

        음성 메모의 "녹음 가져오기" 동작은 단축어 목록에서 검색되지 않아 직접 만들 수 없기 때문에, Wiret이 대신 만들어 드립니다.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func showShortcutRemovalAlert() {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "단축어 앱에서 삭제해주세요"
        alert.informativeText = "macOS는 앱이 단축어를 직접 지우는 것을 허용하지 않습니다. 단축어 앱에서 \(VoiceMemosImporter.defaultShortcutName)을 열어 두었으니, 목록에서 선택한 뒤 ⌘⌫ 로 삭제해주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func showShortcutErrorAlert(_ error: VoiceMemosShortcutError) {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "단축어를 만들지 못했습니다"
        alert.informativeText = error.errorDescription ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func showVoiceMemosErrorAlert(_ error: VoiceMemosImportError) {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "음성 메모로 가져오지 못했습니다"
        alert.informativeText = (error.errorDescription ?? "") + "\n\n녹음 파일은 ~/Music/Wiret 에 그대로 남아 있습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func showLaunchAtLoginApprovalAlert() {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "로그인 항목에서 Wiret을 허용해주세요"
        alert.informativeText = "시스템 설정 > 일반 > 로그인 항목을 열어 두었습니다. 목록에서 Wiret을 허용하면 로그인할 때 자동으로 실행됩니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func showLaunchAtLoginErrorAlert(_ error: Error) {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "로그인 시 실행을 바꾸지 못했습니다"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func showErrorAlert(_ error: Error) {
        if suppressAlertsForTesting { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "녹음 오류"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

/// "업데이트 확인" 항목이 보여 주는 수동 확인 결과. 결과를 창 대신 항목 문구로 알린다.
enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate
    case failed(UpdateError)

    var title: String {
        switch self {
        case .idle: return "업데이트 확인"
        case .checking: return "업데이트 확인 중…"
        case .upToDate: return "최신 버전입니다"
        // 누르면 다시 확인하므로 그 사실을 문구에 담는다.
        case .failed: return "업데이트 확인 실패 · 다시 시도"
        }
    }
}
