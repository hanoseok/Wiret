import AppKit

/// 누르면 메뉴를 닫지 않고 일을 하는 메뉴 항목.
///
/// NSMenu는 일반 항목을 누르면 닫히지만 `NSMenuItem.view` 안의 클릭은 뷰에 맡기고 열어 둔다.
/// 업데이트 확인처럼 결과를 그 자리에서 보여 주고 싶은 항목에 쓴다.
/// 겉모습은 다른 메뉴 항목과 같아야 눌러도 되는 항목으로 보이므로 글꼴·여백·강조를 흉내 낸다.
final class MenuActionItemView: NSView {
    /// 체크마크 칸만큼 비워 두어야 글자가 다른 항목과 같은 줄에 선다.
    private static let leadingInset: CGFloat = 21
    private static let trailingInset: CGFloat = 14
    private static let height: CGFloat = 22
    /// 시스템 메뉴의 선택 강조는 가장자리에서 조금 떨어진 둥근 사각형이다.
    private static let highlightInset: CGFloat = 5
    private static let highlightRadius: CGFloat = 4

    var onClick: (() -> Void)?

    var title: String {
        didSet {
            setAccessibilityLabel(title)
            fitWidthToTitle()
            needsDisplay = true
        }
    }

    var isEnabled = true {
        didSet {
            setAccessibilityEnabled(isEnabled)
            needsDisplay = true
        }
    }

    private var isMouseInside = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Self.height))
        // 메뉴가 가장 넓은 항목에 맞춰 넓어지면 이 뷰도 따라 늘어나야 강조가 끝까지 닿는다.
        autoresizingMask = .width
        // 직접 그리는 뷰라 손쓰지 않으면 VoiceOver가 아무것도 읽지 못한다.
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        fitWidthToTitle()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick()
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 마우스를 쓰지 않고도 클릭을 흉내 낼 수 있게 한다. 테스트가 이 경로로 누른다.
    func performClick() {
        guard isEnabled else { return }
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        performClick()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 메뉴가 닫힐 때는 mouseExited가 오지 않을 수 있다. 다시 열 때 강조가 남아 있지 않게 한다.
        isMouseInside = false
    }

    override func draw(_ dirtyRect: NSRect) {
        // 강조 여부는 그릴 때마다 다시 본다. 키보드로 옮겨 온 강조는 AppKit이 다시 그리기만 요청하기 때문이다.
        let highlighted = isHighlighted
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            let rect = bounds.insetBy(dx: Self.highlightInset, dy: 0)
            NSBezierPath(roundedRect: rect, xRadius: Self.highlightRadius, yRadius: Self.highlightRadius).fill()
        }

        let color: NSColor
        if !isEnabled {
            color = .disabledControlTextColor
        } else if highlighted {
            color = .selectedMenuItemTextColor
        } else {
            color = .controlTextColor
        }
        let text = NSAttributedString(string: title, attributes: titleAttributes(color: color))
        let size = text.size()
        let textRect = NSRect(
            x: Self.leadingInset,
            y: (bounds.height - size.height) / 2,
            width: bounds.width - Self.leadingInset - Self.trailingInset,
            height: size.height
        )
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// 비활성화된 동안에는 강조하지 않는다. 눌러도 되는 것처럼 보이면 안 된다.
    private var isHighlighted: Bool {
        isEnabled && (isMouseInside || enclosingMenuItem?.isHighlighted == true)
    }

    private func titleAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    /// 메뉴 폭은 항목이 요구하는 폭 중 가장 큰 값으로 정해진다. 글자가 잘리지 않을 만큼은 요구한다.
    private func fitWidthToTitle() {
        let textWidth = NSAttributedString(string: title, attributes: titleAttributes(color: .controlTextColor)).size().width
        let width = ceil(textWidth) + Self.leadingInset + Self.trailingInset
        setFrameSize(NSSize(width: max(frame.width, width), height: Self.height))
    }
}
