import AppKit

/// Floating panel asking which of several overlapping meetings should be recorded.
final class MeetingChoiceWindowController: NSWindowController, NSWindowDelegate {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private let meetings: [Meeting]
    private let chooseHandler: (Meeting) -> Void
    private let skipHandler: () -> Void
    private var radioButtons: [NSButton] = []
    private var didFinish = false

    init(meetings: [Meeting], onChoose: @escaping (Meeting) -> Void, onSkip: @escaping () -> Void) {
        self.meetings = meetings
        self.chooseHandler = onChoose
        self.skipHandler = onSkip

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "겹치는 회의 선택"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        super.init(window: panel)

        panel.delegate = self
        let content = makeContentView()
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close without treating it as a skip (the prompt is no longer relevant).
    func dismiss() {
        didFinish = true
        close()
    }

    private func makeContentView() -> NSView {
        let label = NSTextField(wrappingLabelWithString: "같은 시간에 회의가 여러 개 있습니다. 녹음할 회의를 선택하세요.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let radioStack = NSStackView()
        radioStack.orientation = .vertical
        radioStack.alignment = .leading
        radioStack.spacing = 6
        for (index, meeting) in meetings.enumerated() {
            let title = "\(meeting.title)  \(Self.timeFormatter.string(from: meeting.start))–\(Self.timeFormatter.string(from: meeting.end))"
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(selectMeeting(_:)))
            button.tag = index
            button.state = index == 0 ? .on : .off
            radioButtons.append(button)
            radioStack.addArrangedSubview(button)
        }

        let startButton = NSButton(title: "녹음 시작", target: self, action: #selector(confirmSelection))
        startButton.keyEquivalent = "\r"

        let skipButton = NSButton(title: "건너뛰기", target: self, action: #selector(skipSelection))
        skipButton.keyEquivalent = "\u{1b}"

        let buttonStack = NSStackView(views: [skipButton, startButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let stack = NSStackView(views: [label, radioStack, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        buttonStack.trailingAnchor.constraint(equalTo: label.trailingAnchor).isActive = true
        return stack
    }

    @objc private func selectMeeting(_ sender: NSButton) {
        for button in radioButtons {
            button.state = button === sender ? .on : .off
        }
    }

    // The handlers below are dispatched asynchronously: they typically drop the last reference to this
    // controller, which must not happen while it is still running one of its own actions.
    @objc func confirmSelection() {
        guard let index = radioButtons.firstIndex(where: { $0.state == .on }), index < meetings.count else {
            return
        }
        let meeting = meetings[index]
        let handler = chooseHandler
        didFinish = true
        close()
        DispatchQueue.main.async { handler(meeting) }
    }

    @objc func skipSelection() {
        let handler = skipHandler
        didFinish = true
        close()
        DispatchQueue.main.async { handler() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        let handler = skipHandler
        DispatchQueue.main.async { handler() }
    }
}
