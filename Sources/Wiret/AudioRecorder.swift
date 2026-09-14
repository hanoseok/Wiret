import Foundation
import AVFoundation

enum AudioRecorderError: LocalizedError {
    case failedToStart
    case stoppedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            return "녹음을 시작하지 못했습니다."
        case .stoppedUnexpectedly:
            return "녹음이 예기치 않게 중단되었습니다."
        }
    }
}

final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?

    var onUnexpectedStop: ((Error?) -> Void)?

    var isRecording: Bool {
        recorder?.isRecording ?? false
    }

    var hasActiveRecorder: Bool {
        recorder != nil
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async {
                completion(true)
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                completion(false)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        @unknown default:
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func start(title: String? = nil) throws -> URL {
        if recorder != nil {
            _ = stop()
        }

        let fileManager = FileManager.default
        let musicDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Music/Wiret")
        try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)

        let url = RecordingFileNamer.fileURL(in: musicDirectory, date: Date(), title: title)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.delegate = self
        newRecorder.prepareToRecord()
        guard newRecorder.record() else {
            throw AudioRecorderError.failedToStart
        }

        recorder = newRecorder
        return url
    }

    func stop() -> URL? {
        guard let recorder else { return nil }
        let url = recorder.url
        self.recorder = nil
        recorder.stop()
        return url
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard recorder === self.recorder else { return }
        self.recorder = nil
        let error: Error? = flag ? nil : AudioRecorderError.stoppedUnexpectedly
        DispatchQueue.main.async { [onUnexpectedStop] in
            onUnexpectedStop?(error)
        }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard recorder === self.recorder else { return }
        recorder.stop()
        self.recorder = nil
        let reportedError = error ?? AudioRecorderError.stoppedUnexpectedly
        DispatchQueue.main.async { [onUnexpectedStop] in
            onUnexpectedStop?(reportedError)
        }
    }
}
