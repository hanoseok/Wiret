import Foundation

/// 음성 메모 "녹음 가져오기" 동작을 담은 단축어를 만들어 설치까지 이어주는 타입.
///
/// 이 동작은 인텐트 정의에 `isDiscoverable: false`로 표시돼 있어 단축어 앱의 동작 목록에서
/// 검색되지 않는다. 즉 사용자가 손으로 만들 수가 없다. 대신 동작 식별자를 직접 적은 단축어
/// 파일을 만들어 `shortcuts sign`으로 서명한 뒤 단축어 앱에 넘긴다.
enum VoiceMemosShortcutError: LocalizedError, Equatable {
    case signingFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .signingFailed(let message):
            return message.isEmpty
                ? "단축어에 서명하지 못했습니다."
                : "단축어에 서명하지 못했습니다. (\(message))"
        case .writeFailed(let message):
            return "단축어 파일을 만들지 못했습니다. (\(message))"
        }
    }
}

protocol ShortcutInstalling {
    func sign(unsigned: URL, signed: URL) -> ShortcutRunResult
    /// 서명된 단축어를 단축어 앱으로 넘겨 사용자가 추가할 수 있게 한다.
    func open(_ url: URL)
    /// 이미 설치된 단축어를 단축어 앱에서 연다.
    func view(shortcutNamed name: String) -> ShortcutRunResult
}

final class VoiceMemosShortcutInstaller {
    /// 음성 메모의 가져오기 인텐트 식별자. 앱 번들 식별자 + 인텐트 이름 형식이다.
    static let importActionIdentifier = "com.apple.VoiceMemos.RCImportRecording"

    let shortcutName: String
    private let installer: ShortcutInstalling
    private let fileManager: FileManager

    init(
        shortcutName: String = VoiceMemosImporter.defaultShortcutName,
        installer: ShortcutInstalling = ShortcutsCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.shortcutName = shortcutName
        self.installer = installer
        self.fileManager = fileManager
    }

    /// 단축어를 만들고 서명한 뒤 단축어 앱에 넘긴다.
    /// - Returns: 서명된 파일 경로. 실제 추가는 사용자가 단축어 앱에서 확인해야 끝난다.
    func install(in directory: URL? = nil) -> Result<URL, VoiceMemosShortcutError> {
        let workingDirectory = directory ?? fileManager.temporaryDirectory
            .appendingPathComponent("WiretShortcut-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        // `shortcuts sign`은 입력 파일의 확장자가 .shortcut이 아니면 형식 오류로 거부한다.
        let unsigned = workingDirectory.appendingPathComponent("\(shortcutName)-unsigned.shortcut")
        let signed = workingDirectory.appendingPathComponent("\(shortcutName).shortcut")

        do {
            try workflowData().write(to: unsigned)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        let result = installer.sign(unsigned: unsigned, signed: signed)
        guard result.didSucceed else {
            return .failure(.signingFailed(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        installer.open(signed)
        return .success(signed)
    }

    /// 단축어 앱에서 해당 단축어를 연다. macOS는 앱이 단축어를 직접 지우는 것을 허용하지 않아,
    /// 삭제는 사용자가 단축어 앱에서 마무리해야 한다.
    @discardableResult
    func openForRemoval() -> ShortcutRunResult {
        installer.view(shortcutNamed: shortcutName)
    }

    /// 단축어 파일(plist) 내용.
    func workflowData() throws -> Data {
        let action: [String: Any] = [
            "WFWorkflowActionIdentifier": Self.importActionIdentifier,
            "WFWorkflowActionParameters": [
                // 단축어 입력으로 들어온 파일을 그대로 오디오 파일 파라미터에 연결한다.
                "audioFile": [
                    "WFSerializationType": "WFTextTokenAttachment",
                    "Value": ["Type": "ExtensionInput"]
                ]
            ]
        ]

        let workflow: [String: Any] = [
            "WFWorkflowClientVersion": "1200",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowImportQuestions": [],
            "WFWorkflowTypes": ["NCWidget"],
            "WFWorkflowInputContentItemClasses": ["WFFileContentItem"],
            "WFWorkflowIcon": [
                "WFWorkflowIconGlyphNumber": 59511,
                "WFWorkflowIconStartColor": 4292093695
            ],
            "WFWorkflowActions": [action]
        ]

        return try PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0)
    }
}
