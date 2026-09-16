// MouseIcon.swift 뒤에 이어 붙여 실행하는 진입점.
// build_app.sh 가 `cat Sources/Wiret/MouseIcon.swift Scripts/export_app_icon_main.swift | swift - <out>` 로 호출한다.
// 아이콘을 저장소에 바이너리로 두지 않고 빌드할 때마다 같은 코드에서 생성하기 위한 구조다.

func writePNG(_ image: NSImage, to path: String) {
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
    ) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("출력 디렉터리를 지정하세요\n".utf8))
    exit(1)
}
let iconset = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// iconutil 이 요구하는 이름 규칙.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    writePNG(MouseIcon.appIconImage(size: variant.pixels), to: "\(iconset)/\(variant.name).png")
}
print("아이콘 \(variants.count)종 생성: \(iconset)")
