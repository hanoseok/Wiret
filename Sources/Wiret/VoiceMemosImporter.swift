import Foundation

/// 음성 메모 앱은 외부에서 파일을 넣을 공개 경로가 하나뿐이다.
/// 문서 타입(`CFBundleDocumentTypes`)도, URL 스킴도, AppleScript 사전도 없고
/// 저장 폴더(`~/Library/Group Containers/group.com.apple.VoiceMemos.shared`)는 TCC로 막혀 있다.
/// 유일하게 열려 있는 길이 음성 메모가 제공하는 "녹음 가져오기" App Intent이며,
/// 이 인텐트는 단축어(Shortcuts)를 통해 `shortcuts run`으로 호출할 수 있다.
///
/// 단축어를 앱이 대신 설치하는 공개 API는 없으므로, 사용자가 단축어 앱에서 한 번 만들어 두어야 한다.
struct ShortcutRunResult {
    let exitCode: Int32
    let errorOutput: String

    var didSucceed: Bool { exitCode == 0 }
}

protocol ShortcutRunning {
    func shortcutNames() -> [String]
    func run(shortcutName: String, inputPath: String) -> ShortcutRunResult
}

enum VoiceMemosImportError: LocalizedError, Equatable {
    case recordingUnavailable
    case shortcutMissing(String)
    case shortcutFailed(String)

    var errorDescription: String? {
        switch self {
        case .recordingUnavailable:
            return "가져올 녹음 파일이 없습니다."
        case .shortcutMissing(let name):
            return "\"\(name)\" 단축어를 찾을 수 없어 음성 메모로 가져오지 못했습니다."
        case .shortcutFailed(let message):
            return message.isEmpty
                ? "음성 메모로 가져오지 못했습니다."
                : "음성 메모로 가져오지 못했습니다. (\(message))"
        }
    }
}

final class VoiceMemosImporter {
    /// 사용자가 단축어 앱에서 만들어야 하는 단축어 이름.
    static let defaultShortcutName = "Wiret 음성 메모 가져오기"

    let shortcutName: String
    private let runner: ShortcutRunning
    private let fileManager: FileManager

    init(
        shortcutName: String = VoiceMemosImporter.defaultShortcutName,
        runner: ShortcutRunning = ShortcutsCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.shortcutName = shortcutName
        self.runner = runner
        self.fileManager = fileManager
    }

    var isShortcutInstalled: Bool {
        runner.shortcutNames().contains(shortcutName)
    }

    /// 녹음을 음성 메모로 가져온다.
    ///
    /// 원본 삭제는 단축어가 성공(exit code 0)을 반환했을 때만 한다. 가져오기가 실패했는데 원본까지
    /// 지우면 녹음이 통째로 사라지므로, 실패 경로에서는 파일을 건드리지 않는다.
    @discardableResult
    func importRecording(at url: URL, deletingOriginal: Bool) -> Result<Void, VoiceMemosImportError> {
        guard hasAudio(at: url) else {
            return .failure(.recordingUnavailable)
        }
        guard isShortcutInstalled else {
            return .failure(.shortcutMissing(shortcutName))
        }

        let result = runner.run(shortcutName: shortcutName, inputPath: url.path)
        guard result.didSucceed else {
            return .failure(.shortcutFailed(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        if deletingOriginal {
            try? fileManager.removeItem(at: url)
        }
        return .success(())
    }

    /// 녹음이 시작되자마자 끊기면 0바이트 파일이 남는다. 빈 녹음은 가져오지 않는다.
    private func hasAudio(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }
}

/// `/usr/bin/shortcuts`를 호출하는 실제 구현.
final class ShortcutsCommandRunner: ShortcutRunning {
    private static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// 단축어 실행이 멈춰도 앱 종료를 막지 않도록 상한을 둔다.
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func shortcutNames() -> [String] {
        let result = execute(arguments: ["list"])
        guard result.exitCode == 0 else { return [] }
        return result.standardOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func run(shortcutName: String, inputPath: String) -> ShortcutRunResult {
        let result = execute(arguments: ["run", shortcutName, "--input-path", inputPath])
        return ShortcutRunResult(exitCode: result.exitCode, errorOutput: result.standardError)
    }

    private struct ExecutionResult {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    private func execute(arguments: [String]) -> ExecutionResult {
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return ExecutionResult(exitCode: -1, standardOutput: "", standardError: error.localizedDescription)
        }

        // 파이프를 먼저 비워야 출력이 버퍼를 채웠을 때 교착에 빠지지 않는다.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return ExecutionResult(exitCode: -1, standardOutput: "", standardError: "시간이 초과되었습니다.")
        }
        process.waitUntilExit()

        return ExecutionResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
