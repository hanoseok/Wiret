import CoreAudio
import Foundation

/// CoreAudio가 보고하는 프로세스 하나의 오디오 입력 상태.
struct AudioProcessInfo: Equatable {
    let bundleID: String?
    let isRunningInput: Bool
}

/// 다른 앱이 마이크로 녹음 중인지 판단하는 규칙.
///
/// 번들 식별자로 콕 집어 보는 이유는, 마이크를 쓰는 아무 앱이나 막으면 화상 회의 중에
/// 자동 녹음이 통째로 멈추기 때문이다. 정작 녹음이 가장 필요한 순간이 회의 중이다.
enum ExternalRecording {
    static let voiceMemosBundleID = "com.apple.VoiceMemos"

    static func isRecording(bundleID: String, in processes: [AudioProcessInfo]) -> Bool {
        processes.contains { $0.bundleID == bundleID && $0.isRunningInput }
    }
}

protocol ExternalRecordingDetecting: AnyObject {
    var isVoiceMemosRecording: Bool { get }
}

/// CoreAudio의 프로세스 객체 목록을 읽어 음성 메모가 녹음 중인지 본다.
///
/// `kAudioHardwarePropertyProcessObjectList`와 `kAudioProcessPropertyIsRunningInput`은
/// macOS 14.2에서 들어왔지만 헤더에 가용성 주석이 없어 구버전 타깃에서도 컴파일된다.
/// 더 낮은 macOS에서는 조회가 실패하고, 그때는 "감지되지 않음"으로 떨어져 기존 동작을 유지한다.
final class CoreAudioRecordingDetector: ExternalRecordingDetecting {
    private let bundleID: String

    init(bundleID: String = ExternalRecording.voiceMemosBundleID) {
        self.bundleID = bundleID
    }

    var isVoiceMemosRecording: Bool {
        ExternalRecording.isRecording(bundleID: bundleID, in: audioProcesses())
    }

    func audioProcesses() -> [AudioProcessInfo] {
        processObjectIDs().map { id in
            AudioProcessInfo(
                bundleID: stringProperty(id, selector: kAudioProcessPropertyBundleID),
                isRunningInput: boolProperty(id, selector: kAudioProcessPropertyIsRunningInput)
            )
        }
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    private func boolProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }
}
