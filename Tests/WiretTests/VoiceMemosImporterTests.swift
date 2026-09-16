import XCTest
@testable import Wiret

private final class FakeShortcutRunner: ShortcutRunning {
    var installedNames: [String] = [VoiceMemosImporter.defaultShortcutName]
    var resultToReturn = ShortcutRunResult(exitCode: 0, errorOutput: "")
    private(set) var runCount = 0
    private(set) var lastShortcutName: String?
    private(set) var lastInputPath: String?

    func shortcutNames() -> [String] {
        installedNames
    }

    func run(shortcutName: String, inputPath: String) -> ShortcutRunResult {
        runCount += 1
        lastShortcutName = shortcutName
        lastInputPath = inputPath
        return resultToReturn
    }
}

final class VoiceMemosImporterTests: XCTestCase {
    private var runner: FakeShortcutRunner!
    private var directory: URL!

    override func setUp() {
        super.setUp()
        runner = FakeShortcutRunner()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemosImporterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        runner = nil
        directory = nil
        super.tearDown()
    }

    private func makeRecording(named name: String = "Wiret-20260101-090000.m4a", bytes: Int = 1024) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(at: url, contents: Data(repeating: 0, count: bytes))
        return url
    }

    private func makeImporter() -> VoiceMemosImporter {
        VoiceMemosImporter(runner: runner)
    }

    func testImportRunsShortcutWithRecordingPath() {
        let url = makeRecording()

        let result = makeImporter().importRecording(at: url, deletingOriginal: false)

        XCTAssertEqual(runner.runCount, 1)
        XCTAssertEqual(runner.lastShortcutName, VoiceMemosImporter.defaultShortcutName)
        XCTAssertEqual(runner.lastInputPath, url.path)
        XCTAssertNoThrow(try result.get())
    }

    func testSuccessfulImportDeletesOriginalWhenRequested() {
        let url = makeRecording()

        let result = makeImporter().importRecording(at: url, deletingOriginal: true)

        XCTAssertNoThrow(try result.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSuccessfulImportKeepsOriginalWhenNotRequested() {
        let url = makeRecording()

        _ = makeImporter().importRecording(at: url, deletingOriginal: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 가져오기가 실패했는데 원본까지 지우면 녹음이 사라진다. 실패 시에는 반드시 남아 있어야 한다.
    func testFailedImportKeepsOriginal() {
        let url = makeRecording()
        runner.resultToReturn = ShortcutRunResult(exitCode: 1, errorOutput: "boom")

        let result = makeImporter().importRecording(at: url, deletingOriginal: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        guard case .failure(.shortcutFailed) = result else {
            return XCTFail("실패 결과를 기대했지만 \(result)")
        }
    }

    func testMissingShortcutFailsWithoutRunningOrDeleting() {
        let url = makeRecording()
        runner.installedNames = ["다른 단축어"]

        let result = makeImporter().importRecording(at: url, deletingOriginal: true)

        XCTAssertEqual(runner.runCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        guard case .failure(.shortcutMissing(let name)) = result else {
            return XCTFail("단축어 없음 결과를 기대했지만 \(result)")
        }
        XCTAssertEqual(name, VoiceMemosImporter.defaultShortcutName)
    }

    func testMissingFileIsNotImported() {
        let url = directory.appendingPathComponent("없는파일.m4a")

        let result = makeImporter().importRecording(at: url, deletingOriginal: true)

        XCTAssertEqual(runner.runCount, 0)
        guard case .failure(.recordingUnavailable) = result else {
            return XCTFail("파일 없음 결과를 기대했지만 \(result)")
        }
    }

    /// 녹음이 시작되자마자 중단되면 0바이트 파일이 남는다. 음성 메모에 빈 녹음을 넣지 않는다.
    func testEmptyFileIsNotImported() {
        let url = makeRecording(bytes: 0)

        let result = makeImporter().importRecording(at: url, deletingOriginal: true)

        XCTAssertEqual(runner.runCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        guard case .failure(.recordingUnavailable) = result else {
            return XCTFail("파일 없음 결과를 기대했지만 \(result)")
        }
    }

    func testIsShortcutInstalledReflectsRunnerList() {
        let importer = makeImporter()
        XCTAssertTrue(importer.isShortcutInstalled)

        runner.installedNames = []
        XCTAssertFalse(importer.isShortcutInstalled)
    }

    func testCustomShortcutNameIsUsed() {
        let url = makeRecording()
        runner.installedNames = ["내 단축어"]
        let importer = VoiceMemosImporter(shortcutName: "내 단축어", runner: runner)

        _ = importer.importRecording(at: url, deletingOriginal: false)

        XCTAssertEqual(runner.lastShortcutName, "내 단축어")
    }
}

private extension FileManager {
    func createFile(at url: URL, contents: Data) {
        createFile(atPath: url.path, contents: contents)
    }
}
