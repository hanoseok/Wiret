import AppKit

/// 회의 시작·종료 알림. 시스템 알림처럼 화면 오른쪽 위에 떠서 답할 때까지 남아 있는다.
///
/// 시스템 알림(UserNotifications)은 사용자가 따로 허용해야 하고 시간이 지나면 알림 센터로 사라진다.
/// 답할 때까지 눈앞에 남아 있고 "몇 분 후 종료" 같은 선택지도 담을 수 있도록 떠 있는 패널로 직접 그린다.
final class MeetingNotificationWindowController: NSWindowController, NSWindowDelegate {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 시스템 알림처럼 화면 모서리에서 살짝 띄운다.
    private static let screenInset: CGFloat = 16

    let prompt: MeetingNotificationPrompt
    private let delayOptions: [Int]
    private let responseHandler: (MeetingNotificationResponse) -> Void
    private var didFinish = false
    /// "몇 분 후 종료" 선택 메뉴. 종료 알림에만 있다.
    private(set) var delayPopUp: NSPopUpButton?

    init(
        prompt: MeetingNotificationPrompt,
        delayOptions: [Int] = MeetingNotificationCoordinator.delayOptions,
        onResponse: @escaping (MeetingNotificationResponse) -> Void
    ) {
        self.prompt = prompt
        self.delayOptions = delayOptions
        self.responseHandler = onResponse

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        switch prompt {
        case .start: panel.title = "회의 시작"
        case .end: panel.title = "회의 종료"
        }
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 화상 회의 앱을 전체 화면으로 띄워 둔 상태에서도 보여야 한다.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init(window: panel)

        panel.delegate = self
        let content = makeContentView()
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        placeAtTopRight(panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 앞으로 띄우기만 하고 포커스는 가져오지 않는다. 화상 회의나 메신저 채팅에 입력하던 중에 알림이 떠
    /// 키 창이 되면, 치던 Return이 "지금 종료"를 눌러 버린다. 제목 막대가 있는 패널이라 클릭하면 키 창이
    /// 되고(.nonactivatingPanel이라 앱은 활성화되지 않는다), 그다음부터 Return/Esc가 동작한다.
    func show() {
        window?.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
    }

    /// 답으로 치지 않고 닫는다(알림이 더 이상 의미가 없을 때).
    func dismiss() {
        didFinish = true
        close()
    }

    private func placeAtTopRight(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - Self.screenInset,
            y: visible.maxY - size.height - Self.screenInset
        ))
    }

    private func makeContentView() -> NSView {
        let meeting: Meeting
        let message: String
        let buttons: [NSView]

        switch prompt {
        case .start(let m):
            meeting = m
            let time = "\(Self.timeFormatter.string(from: m.start))–\(Self.timeFormatter.string(from: m.end))"
            message = "\(time) 회의가 시작됐습니다. 녹음을 시작할까요?"

            let cancelButton = NSButton(title: "취소", target: self, action: #selector(cancel))
            cancelButton.keyEquivalent = "\u{1b}"
            let startButton = NSButton(title: "녹음 시작", target: self, action: #selector(confirmStart))
            startButton.keyEquivalent = "\r"
            buttons = [cancelButton, startButton]

        case .end(let m):
            meeting = m
            message = "\(Self.timeFormatter.string(from: m.end)) 회의 종료 시간이 됐습니다. 녹음을 어떻게 할까요?"

            let cancelButton = NSButton(title: "취소", target: self, action: #selector(cancel))
            cancelButton.keyEquivalent = "\u{1b}"

            // 풀다운 메뉴의 첫 항목은 버튼 제목으로만 쓰인다.
            let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
            popUp.addItem(withTitle: "몇 분 후 종료")
            for minutes in delayOptions {
                popUp.addItem(withTitle: "\(minutes)분 후")
                popUp.lastItem?.tag = minutes
            }
            popUp.target = self
            popUp.action = #selector(delayChosen(_:))
            delayPopUp = popUp

            let stopButton = NSButton(title: "지금 종료", target: self, action: #selector(stopNow))
            stopButton.keyEquivalent = "\r"
            buttons = [cancelButton, popUp, stopButton]
        }

        let heading = NSTextField(labelWithString: meeting.title)
        heading.font = .boldSystemFont(ofSize: 13)
        heading.lineBreakMode = .byTruncatingTail
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let buttonStack = NSStackView(views: buttons)
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let stack = NSStackView(views: [heading, label, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: label)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 16, right: 20)
        buttonStack.trailingAnchor.constraint(equalTo: label.trailingAnchor).isActive = true
        return stack
    }

    @objc private func delayChosen(_ sender: NSPopUpButton) {
        guard let minutes = sender.selectedItem?.tag, minutes > 0 else { return }
        stopLater(minutes: minutes)
    }

    // 아래 응답은 비동기로 넘긴다. 응답을 받은 쪽이 이 컨트롤러의 마지막 참조를 놓는 경우가 많은데,
    // 자기 동작을 실행하는 도중에 해제되면 안 된다.
    @objc func confirmStart() {
        finish(with: .startRecording)
    }

    @objc func stopNow() {
        finish(with: .stopNow)
    }

    func stopLater(minutes: Int) {
        finish(with: .stopLater(minutes: minutes))
    }

    @objc func cancel() {
        finish(with: .cancel)
    }

    private func finish(with response: MeetingNotificationResponse) {
        guard !didFinish else { return }
        let handler = responseHandler
        didFinish = true
        close()
        DispatchQueue.main.async { handler(response) }
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        let handler = responseHandler
        DispatchQueue.main.async { handler(.cancel) }
    }
}
