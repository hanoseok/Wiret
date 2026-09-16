import AppKit

/// Wiret의 쥐 아이콘을 코드로 그린다.
///
/// 이미지 파일 대신 베지어 패스로 그리는 이유는 메뉴 막대(18pt)부터 앱 아이콘(1024pt)까지
/// 같은 도형을 어느 크기로든 선명하게 쓰기 위해서다.
///
/// 그리는 순서가 중요하다. 귀와 머리는 서로 겹치므로 한 패스에 담아 nonZero 규칙으로 합집합을
/// 만들고, 눈·코·귀 안쪽은 그 뒤에 `.clear` 블렌드로 뚫는다. 짝홀(evenOdd) 규칙으로 한 번에
/// 그리면 겹친 자리가 파여서 실루엣이 깨진다.
enum MouseIcon {
    /// 도형을 그리는 기준 정사각형. 이 좌표계로 그린 뒤 원하는 크기로 스케일한다.
    private static let canvas: CGFloat = 100

    /// 메뉴 막대는 18pt라 픽셀이 몇 개 안 된다. 그 크기에서 꼬리는 얼룩으로, 코는 진흙으로
    /// 뭉개지므로 얼굴만 남기고, 앱 아이콘에서는 꼬리와 코까지 그린다.
    private enum Style {
        case menuBar
        case appIcon

        var drawsTail: Bool { self == .appIcon }
        var drawsNose: Bool { self == .appIcon }
        /// 작은 크기에서 사라지지 않도록 메뉴 막대 쪽 눈을 키운다.
        var eyeSize: CGFloat { self == .menuBar ? 16 : 12 }
    }

    /// 메뉴 막대용 이미지. 템플릿으로 표시해 라이트/다크 메뉴 막대에 자동으로 맞춘다.
    /// - Parameter recording: 녹음 중이면 왼쪽 아래에 녹음 점을 찍어 유휴 상태와 구분한다.
    static func menuBarImage(size: CGFloat = 18, recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(scale: size / canvas, bodyColor: .black, style: .menuBar, recording: recording)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Wiret 녹음 중" : "Wiret"
        return image
    }

    /// 앱 아이콘용 컬러 이미지. 둥근 사각형 바탕 위에 같은 쥐를 올린다.
    static func appIconImage(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let scale = size / canvas

            NSGraphicsContext.saveGraphicsState()
            let backgroundTransform = NSAffineTransform()
            backgroundTransform.scale(by: scale)
            backgroundTransform.concat()

            let background = NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: canvas, height: canvas),
                xRadius: canvas * 0.22,
                yRadius: canvas * 0.22
            )
            NSGradient(
                starting: NSColor(calibratedRed: 0.45, green: 0.50, blue: 0.66, alpha: 1),
                ending: NSColor(calibratedRed: 0.18, green: 0.21, blue: 0.33, alpha: 1)
            )?.draw(in: background, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            // 쥐를 바탕 안쪽으로 줄여 여백을 준다.
            let inset = scale * 0.74
            let offset = size * 0.13
            draw(
                scale: inset,
                translate: NSPoint(x: offset, y: offset * 1.1),
                bodyColor: NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.98, alpha: 1),
                style: .appIcon,
                recording: false
            )
            return true
        }
    }

    private static func draw(
        scale: CGFloat,
        translate: NSPoint = .zero,
        bodyColor: NSColor,
        style: Style,
        recording: Bool
    ) {
        guard let context = NSGraphicsContext.current else { return }

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: translate.x, yBy: translate.y)
        transform.scale(by: scale)
        transform.concat()

        bodyColor.setFill()
        bodyColor.setStroke()

        // 꼬리를 먼저 그려 몸통 뒤에서 빠져나오게 한다.
        if style.drawsTail {
            tailPath().stroke()
        }
        silhouettePath().fill()
        if recording {
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 20, height: 20)).fill()
        }

        // 눈·코·귀 안쪽은 칠하지 않고 뚫는다. 템플릿 이미지에서도 얼굴이 살아 있게 하려는 것.
        context.cgContext.setBlendMode(.clear)
        holesPath(style: style).fill()
        context.cgContext.setBlendMode(.normal)

        NSGraphicsContext.restoreGraphicsState()
    }

    /// 귀 두 개와 머리를 합집합으로 묶은 실루엣.
    private static func silhouettePath() -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .nonZero
        path.appendOval(in: NSRect(x: 7, y: 57, width: 35, height: 35))   // 왼쪽 귀
        path.appendOval(in: NSRect(x: 55, y: 57, width: 35, height: 35))  // 오른쪽 귀
        path.appendOval(in: NSRect(x: 15, y: 6, width: 66, height: 63))   // 머리
        return path
    }

    /// 실루엣에서 뚫어낼 구멍들.
    private static func holesPath(style: Style) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendOval(in: NSRect(x: 16, y: 66, width: 17, height: 17))  // 왼쪽 귀 안쪽
        path.appendOval(in: NSRect(x: 64, y: 66, width: 17, height: 17))  // 오른쪽 귀 안쪽

        let eye = style.eyeSize
        let eyeY: CGFloat = 32
        path.appendOval(in: NSRect(x: 30 - (eye - 12) / 2, y: eyeY, width: eye, height: eye))
        path.appendOval(in: NSRect(x: 54 + (eye - 12) / 2 - (eye - 12), y: eyeY, width: eye, height: eye))

        if style.drawsNose {
            path.appendOval(in: NSRect(x: 43, y: 15, width: 10, height: 8))
        }
        return path
    }

    /// 오른쪽 아래에서 빠져나와 위로 말리는 꼬리.
    private static func tailPath() -> NSBezierPath {
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 60, y: 14))
        tail.curve(
            to: NSPoint(x: 93, y: 40),
            controlPoint1: NSPoint(x: 88, y: 4),
            controlPoint2: NSPoint(x: 99, y: 20)
        )
        tail.lineWidth = 5
        tail.lineCapStyle = .round
        return tail
    }
}
