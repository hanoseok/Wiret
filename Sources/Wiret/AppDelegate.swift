import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let recorder = AudioRecorder()
    private let calendarSource: MeetingSource
    private let defaults: UserDefaults
    private let voiceMemosImporter: VoiceMemosImporter
    private let shortcutInstaller: VoiceMemosShortcutInstaller
    private(set) lazy var coordinator = AutoRecordingCoordinator(source: calendarSource, defaults: defaults)

    var state: RecordingState = .idle {
        didSet { updateMenu() }
    }

    private(set) var statusItem: NSStatusItem!
    private(set) var startItem: NSMenuItem!
    private(set) var stopItem: NSMenuItem!
    private(set) var autoItem: NSMenuItem!
    private(set) var autoStatusItem: NSMenuItem!
    private(set) var calendarItem: NSMenuItem!
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
    private var wakeObserver: NSObjectProtocol?
    var suppressAlertsForTesting = false

    init(
        defaults: UserDefaults = .standard,
        voiceMemosImporter: VoiceMemosImporter = VoiceMemosImporter(),
        shortcutInstaller: VoiceMemosShortcutInstaller = VoiceMemosShortcutInstaller(),
        calendarSource: MeetingSource = EventKitMeetingSource()
    ) {
        self.defaults = defaults
        self.calendarSource = calendarSource
        self.voiceMemosImporter = voiceMemosImporter
        self.shortcutInstaller = shortcutInstaller
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

        autoStatusItem = NSMenuItem(title: "자동: 꺼짐", action: nil, keyEquivalent: "")
        autoStatusItem.isEnabled = false
        menu.addItem(autoStatusItem)

        calendarItem = NSMenuItem(title: "캘린더", action: nil, keyEquivalent: "")
        let calendarMenu = NSMenu()
        calendarMenu.autoenablesItems = false
        calendarMenu.delegate = self
        calendarItem.submenu = calendarMenu
        menu.addItem(calendarItem)

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
        coordinator.isStartInFlightProvider = { [weak self] in
            guard let self, self.isStarting else { return false }
            return Date().timeIntervalSince(self.startRequestedAt) < Self.startInFlightTimeout
        }
        coordinator.onStart = { [weak self] meeting in self?.startAutoRecording(for: meeting) }
        coordinator.onStop = { [weak self] in self?.endRecording() }
        coordinator.onStatusText = { [weak self] text in self?.autoStatusItem.title = text }
        coordinator.onAccessDenied = { [weak self] in
            self?.showCalendarDeniedAlert()
            self?.autoItem.state = .off
        }
        coordinator.onChoose = { [weak self] meetings in self?.presentMeetingChoice(meetings) }
        coordinator.onChoiceObsolete = { [weak self] in self?.dismissMeetingChoice() }
        autoItem.state = coordinator.isEnabled ? .on : .off
        calendarSource.selectedCalendarIDs = selectedCalendarIDs
        rebuildCalendarMenu()
        coordinator.start()

        // Waking from sleep: re-check immediately so a meeting that ended while asleep stops right
        // away and a meeting that is now in progress starts.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.coordinator.tick()
        }

        updateMenu()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.warnIfStatusItemHidden()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.releaseForTermination()
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
        if !beginRecording(title: meeting.title) {
            // Busy or already recording: don't leave the coordinator waiting on a recording that never began.
            coordinator.noteAutoStartFailed()
        }
    }

    /// - Returns: whether the start request was accepted (a permission or recorder failure is reported
    ///   asynchronously through `coordinator.noteAutoStartFailed()`).
    @discardableResult
    private func beginRecording(title: String?) -> Bool {
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
                } catch {
                    self.updateMenu()
                    if title != nil {
                        self.coordinator.noteAutoStartFailed()
                    }
                    self.showErrorAlert(error)
                }
            } else {
                self.updateMenu()
                if title != nil {
                    self.coordinator.noteAutoStartFailed()
                }
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
        refreshShortcutItem()
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
        let url = currentRecordingURL
        currentRecordingURL = nil
        if let url {
            importToVoiceMemos(url)
        }
        if let error {
            showErrorAlert(error)
        }
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
