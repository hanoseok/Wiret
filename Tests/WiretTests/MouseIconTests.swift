import AppKit
import XCTest
@testable import Wiret

final class MouseIconTests: XCTestCase {
    /// NSImage는 그릴 때마다 다시 렌더링되므로, 픽셀을 보려면 원하는 크기로 한 번 구워야 한다.
    private func rasterize(_ image: NSImage) -> NSBitmapImageRep? {
        let size = image.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func opaquePixelCount(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                count += 1
            }
        }
        return count
    }

    // MARK: - 메뉴 막대

    /// 템플릿이어야 라이트/다크 메뉴 막대와 강조 색에 자동으로 맞춰진다.
    func testMenuBarImageIsTemplate() {
        XCTAssertTrue(MouseIcon.menuBarImage(recording: false).isTemplate)
        XCTAssertTrue(MouseIcon.menuBarImage(recording: true).isTemplate)
    }

    func testMenuBarImageUsesRequestedSize() {
        let image = MouseIcon.menuBarImage(size: 24, recording: false)
        XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
    }

    func testMenuBarImageDrawsSomething() {
        guard let rep = rasterize(MouseIcon.menuBarImage(size: 64, recording: false)) else {
            return XCTFail("래스터화 실패")
        }
        XCTAssertGreaterThan(opaquePixelCount(rep), 0)
    }

    /// 눈과 귀 안쪽은 뚫려 있어야 한다. 전부 칠해지면 18px에서 검은 덩어리로만 보인다.
    func testMenuBarImageIsNotSolid() {
        guard let rep = rasterize(MouseIcon.menuBarImage(size: 64, recording: false)) else {
            return XCTFail("래스터화 실패")
        }
        let total = rep.pixelsWide * rep.pixelsHigh
        XCTAssertLessThan(opaquePixelCount(rep), total)
    }

    /// 색만으로 구분하면 색각 이상이나 흑백 화면에서 상태를 알 수 없다. 모양도 달라야 한다.
    func testRecordingVariantDiffersFromIdle() {
        guard let idle = rasterize(MouseIcon.menuBarImage(size: 64, recording: false)),
              let recording = rasterize(MouseIcon.menuBarImage(size: 64, recording: true)) else {
            return XCTFail("래스터화 실패")
        }
        XCTAssertNotEqual(opaquePixelCount(idle), opaquePixelCount(recording))
    }

    func testAccessibilityDescriptionDistinguishesRecording() {
        XCTAssertEqual(MouseIcon.menuBarImage(recording: false).accessibilityDescription, "Wiret")
        XCTAssertEqual(MouseIcon.menuBarImage(recording: true).accessibilityDescription, "Wiret 녹음 중")
    }

    // MARK: - 앱 아이콘

    func testAppIconUsesRequestedSize() {
        XCTAssertEqual(MouseIcon.appIconImage(size: 128).size, NSSize(width: 128, height: 128))
    }

    /// 둥근 사각형 바탕이므로 가운데는 칠해져 있고 모서리는 비어 있어야 한다.
    func testAppIconIsRoundedRectangle() {
        guard let rep = rasterize(MouseIcon.appIconImage(size: 128)) else {
            return XCTFail("래스터화 실패")
        }
        XCTAssertGreaterThan(rep.colorAt(x: 64, y: 64)?.alphaComponent ?? 0, 0.9, "가운데가 비어 있습니다")
        XCTAssertLessThan(rep.colorAt(x: 1, y: 1)?.alphaComponent ?? 1, 0.1, "모서리가 둥글지 않습니다")
    }

    /// 앱 아이콘은 컬러로 보여야 하므로 템플릿이면 안 된다.
    func testAppIconIsNotTemplate() {
        XCTAssertFalse(MouseIcon.appIconImage(size: 128).isTemplate)
    }
}
