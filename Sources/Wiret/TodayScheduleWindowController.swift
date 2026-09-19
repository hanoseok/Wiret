import AppKit

/// NSScrollView는 기본적으로 아래에서 위로 쌓이므로, 위에서부터 보이도록 뒤집는다.
private final class TopAlignedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// 오늘 일정을 보여주고, 자동 녹음에서 뺄 회의를 고르게 하는 창.
///
/// 기본은 전부 포함이다. 체크를 끄면 그 회의만 자동 녹음에서 빠진다.
final class TodayScheduleWindowController: NSWindowController, NSWindowDelegate {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M월 d일 (E)"
        return formatter
    }()

    private let meetings: [Meeting]
    private let date: Date
    private let isExcluded: (Meeting) -> Bool
    private let onToggle: (Meeting, Bool) -> Void
    private(set) var checkboxes: [NSButton] = []

    init(
        meetings: [Meeting],
        date: Date = Date(),
        isExcluded: @escaping (Meeting) -> Bool,
        onToggle: @escaping (Meeting, Bool) -> Void
    ) {
        self.meetings = meetings
        self.date = date
        self.isExcluded = isExcluded
        self.onToggle = onToggle

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "오늘의 일정"
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

    func dismiss() {
        close()
    }

    private func makeContentView() -> NSView {
        let heading = NSTextField(labelWithString: Self.dayFormatter.string(from: date))
        heading.font = .boldSystemFont(ofSize: 15)

        let explanation = NSTextField(wrappingLabelWithString: "체크된 회의가 자동 녹음 대상입니다. 녹음하고 싶지 않은 회의는 체크를 끄세요.")
        explanation.textColor = .secondaryLabelColor
        explanation.translatesAutoresizingMaskIntoConstraints = false
        explanation.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 8

        if meetings.isEmpty {
            let empty = NSTextField(labelWithString: "오늘 예정된 회의가 없습니다.")
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
        } else {
            for (index, meeting) in meetings.enumerated() {
                let time = "\(Self.timeFormatter.string(from: meeting.start))–\(Self.timeFormatter.string(from: meeting.end))"
                let button = NSButton(
                    checkboxWithTitle: "\(time)   \(meeting.title)",
                    target: self,
                    action: #selector(toggleMeeting(_:))
                )
                button.tag = index
                button.state = isExcluded(meeting) ? .off : .on
                checkboxes.append(button)
                listStack.addArrangedSubview(button)
            }
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView = TopAlignedClipView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        listStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = listStack

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: clip.topAnchor)
        ])

        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        // 일정이 많아도 창이 화면을 넘지 않게 높이를 묶어 둔다.
        let listHeight = min(max(listStack.fittingSize.height, 24), 320)
        scroll.heightAnchor.constraint(equalToConstant: listHeight).isActive = true

        let closeButton = NSButton(title: "닫기", target: self, action: #selector(closeWindow))
        closeButton.keyEquivalent = "\r"

        let buttonStack = NSStackView(views: [closeButton])
        buttonStack.orientation = .horizontal

        // 회의가 없으면 체크 안내는 가리킬 대상이 없다.
        let views: [NSView] = meetings.isEmpty
            ? [heading, scroll, buttonStack]
            : [heading, explanation, scroll, buttonStack]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        return stack
    }

    /// 테스트에서 체크박스를 직접 누르기 위한 통로.
    func toggleCheckbox(at index: Int) {
        guard index < checkboxes.count else { return }
        let button = checkboxes[index]
        button.state = button.state == .on ? .off : .on
        toggleMeeting(button)
    }

    @objc private func toggleMeeting(_ sender: NSButton) {
        guard sender.tag < meetings.count else { return }
        // 체크가 켜져 있으면 자동 녹음 대상, 꺼져 있으면 제외.
        onToggle(meetings[sender.tag], sender.state == .off)
    }

    @objc private func closeWindow() {
        close()
    }
}
