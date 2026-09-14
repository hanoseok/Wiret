import XCTest
@testable import Wiret

final class AudioRecorderTests: XCTestCase {
    func testStopWithoutRecordingReturnsNil() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.hasActiveRecorder)
        XCTAssertNil(recorder.stop())
        XCTAssertFalse(recorder.hasActiveRecorder)
    }

    func testStoppedUnexpectedlyErrorDescriptionIsNonEmpty() {
        let description = AudioRecorderError.stoppedUnexpectedly.errorDescription
        XCTAssertNotNil(description)
        XCTAssertFalse(description!.isEmpty)
    }
}
