import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recorder = AudioRecorder()
    private let calendarSource = EventKitMeetingSource()
    private let defaults: UserDefaults
    private(set) lazy var coordinator = AutoRecordingCoordinator(source: calendarSource, defaults: defaults)

    var state: RecordingState = .idle {
        didSet { updateMenu() }
    }

    private(set) var statusItem: NSStatusItem!
    private(set) var startItem: NSMenuItem!
    private(set) var stopItem: NSMenuItem!
    private(set) var autoItem: NSMenuItem!
    private(set) var autoStatusItem: NSMenuItem!

    private var isStarting = false
    var suppressAlertsForTesting = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
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

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "종료", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        recorder.onUnexpectedStop = { [weak self] error in
            self?.handleUnexpectedStop(error)
        }

        coordinator.isRecordingProvider = { [weak self] in self?.state == .recording }
        coordinator.isStartInFlightProvider = { [weak self] in self?.isStarting ?? false }
        coordinator.onStart = { [weak self] meeting in self?.startAutoRecording(for: meeting) }
        coordinator.onStop = { [weak self] in self?.endRecording() }
        coordinator.onStatusText = { [weak self] text in self?.autoStatusItem.title = text }
        coordinator.onAccessDenied = { [weak self] in
            self?.showCalendarDeniedAlert()
            self?.autoItem.state = .off
        }
        autoItem.state = coordinator.isEnabled ? .on : .off
        coordinator.start()

        updateMenu()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.warnIfStatusItemHidden()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = recorder.stop()
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
                let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Wiret")
                image?.isTemplate = true
                button.image = image
                button.contentTintColor = nil
            case .recording:
                let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Wiret")
                button.image = image
                button.contentTintColor = .systemRed
            }
        }
    }

    @objc private func startRecording() {
        beginRecording(title: nil)
    }

    private func startAutoRecording(for meeting: Meeting) {
        beginRecording(title: meeting.title)
    }

    private func beginRecording(title: String?) {
        guard state == .idle, !isStarting else {
            return
        }
        isStarting = true
        startItem.isEnabled = false

        recorder.requestPermission { [weak self] granted in
            guard let self else { return }
            self.isStarting = false
            if granted {
                do {
                    _ = try self.recorder.start(title: title)
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
    }

    @objc private func stopRecording() {
        coordinator.noteManualStop()
        endRecording()
    }

    private func endRecording() {
        _ = recorder.stop()
        state = .idle
    }

    @objc private func toggleAuto() {
        coordinator.setEnabled(!coordinator.isEnabled)
        autoItem.state = coordinator.isEnabled ? .on : .off
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
        if let error {
            showErrorAlert(error)
        }
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
