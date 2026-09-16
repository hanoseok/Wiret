import XCTest
@testable import Wiret

private final class FakeShortcutInstaller: ShortcutInstalling {
    var signResult = ShortcutRunResult(exitCode: 0, errorOutput: "")
    var writesOutput = true
    private(set) var signedInputs: [URL] = []
    private(set) var signedOutputs: [URL] = []
    private(set) var openedURLs: [URL] = []
    private(set) var viewedNames: [String] = []

    func sign(unsigned: URL, signed: URL) -> ShortcutRunResult {
        signedInputs.append(unsigned)
        signedOutputs.append(signed)
        if writesOutput {
            try? Data("signed".utf8).write(to: signed)
        }
        return signResult
    }

    func open(_ url: URL) { openedURLs.append(url) }

    func view(shortcutNamed name: String) -> ShortcutRunResult {
        viewedNames.append(name)
        return ShortcutRunResult(exitCode: 0, errorOutput: "")
    }
}

final class VoiceMemosShortcutTests: XCTestCase {
    private var installer: FakeShortcutInstaller!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        installer = FakeShortcutInstaller()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemosShortcutTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        installer = nil
        directory = nil
        super.tearDown()
    }

    private func makeSubject() -> VoiceMemosShortcutInstaller {
        VoiceMemosShortcutInstaller(installer: installer)
    }

    private func workflow() throws -> [String: Any] {
        let data = try makeSubject().workflowData()
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    // MARK: - 단축어 내용

    /// 음성 메모의 가져오기 동작은 단축어 목록에서 검색되지 않아, 식별자를 직접 적어야만 만들 수 있다.
    func testWorkflowUsesVoiceMemosImportAction() throws {
        let actions = try XCTUnwrap(workflow()["WFWorkflowActions"] as? [[String: Any]])
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(
            actions[0]["WFWorkflowActionIdentifier"] as? String,
            "com.apple.VoiceMemos.RCImportRecording"
        )
    }

    /// 파라미터 이름이 틀리면 단축어는 만들어지지만 파일이 전달되지 않는다.
    func testWorkflowConnectsShortcutInputToAudioFileParameter() throws {
        let actions = try XCTUnwrap(workflow()["WFWorkflowActions"] as? [[String: Any]])
        let parameters = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
        let audioFile = try XCTUnwrap(parameters["audioFile"] as? [String: Any])
        let value = try XCTUnwrap(audioFile["Value"] as? [String: Any])

        XCTAssertEqual(value["Type"] as? String, "ExtensionInput")
    }

    /// 입력을 파일로 받지 않으면 `shortcuts run --input-path`로 녹음을 넘길 수 없다.
    func testWorkflowAcceptsFileInput() throws {
        let classes = try XCTUnwrap(workflow()["WFWorkflowInputContentItemClasses"] as? [String])
        XCTAssertTrue(classes.contains("WFFileContentItem"))
    }

    // MARK: - 설치

    /// `shortcuts sign`은 입력 파일 확장자가 .shortcut이 아니면 형식 오류로 거부한다.
    func testSigningInputUsesShortcutExtension() {
        _ = makeSubject().install(in: directory)

        XCTAssertEqual(installer.signedInputs.first?.pathExtension, "shortcut")
        XCTAssertEqual(installer.signedOutputs.first?.pathExtension, "shortcut")
    }

    func testInstallHandsSignedFileToShortcutsApp() {
        let result = makeSubject().install(in: directory)

        guard case .success(let url) = result else {
            return XCTFail("설치 성공을 기대했지만 \(result)")
        }
        XCTAssertEqual(installer.openedURLs, [url])
        XCTAssertEqual(url, installer.signedOutputs.first)
    }

    func testSignedFileIsNamedAfterTheShortcut() {
        _ = makeSubject().install(in: directory)

        XCTAssertEqual(
            installer.signedOutputs.first?.deletingPathExtension().lastPathComponent,
            VoiceMemosImporter.defaultShortcutName
        )
    }

    /// 서명이 실패했는데 단축어 앱을 여는 것은 사용자를 헷갈리게 한다.
    func testFailedSigningDoesNotOpenShortcutsApp() {
        installer.signResult = ShortcutRunResult(exitCode: 1, errorOutput: "형식 오류")

        let result = makeSubject().install(in: directory)

        XCTAssertTrue(installer.openedURLs.isEmpty)
        guard case .failure(.signingFailed(let message)) = result else {
            return XCTFail("서명 실패를 기대했지만 \(result)")
        }
        XCTAssertEqual(message, "형식 오류")
    }

    // MARK: - 삭제

    /// macOS는 앱이 단축어를 직접 지우지 못하게 하므로, 단축어 앱에서 열어주는 것까지가 한계다.
    func testRemovalOpensShortcutInShortcutsApp() {
        makeSubject().openForRemoval()

        XCTAssertEqual(installer.viewedNames, [VoiceMemosImporter.defaultShortcutName])
    }
}
