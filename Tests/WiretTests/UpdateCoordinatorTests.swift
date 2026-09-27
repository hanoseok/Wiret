import XCTest
@testable import Wiret

private final class FakeUpdateChecker: UpdateChecking {
    var releasesResult: Result<[ReleaseInfo], UpdateError> = .success([])
    var downloadResult: Result<URL, UpdateError> = .failure(.network("설정 안 됨"))
    private(set) var fetchCount = 0
    private(set) var downloadedReleases: [ReleaseInfo] = []

    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateError>) -> Void) {
        fetchCount += 1
        completion(releasesResult)
    }

    func download(_ release: ReleaseInfo, completion: @escaping (Result<URL, UpdateError>) -> Void) {
        downloadedReleases.append(release)
        completion(downloadResult)
    }
}

final class UpdateCoordinatorTests: XCTestCase {
    private var checker: FakeUpdateChecker!
    private var offered: [ReleaseInfo] = []
    private var upToDateCount = 0
    private var errors: [UpdateError] = []

    override func setUp() {
        super.setUp()
        checker = FakeUpdateChecker()
        offered = []
        upToDateCount = 0
        errors = []
    }

    private func release(_ tag: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion.parse(tag)!,
            downloadURL: URL(string: "https://example.com/\(tag).zip")!,
            pageURL: nil
        )
    }

    private func makeCoordinator(current: String?) -> UpdateCoordinator {
        let coordinator = UpdateCoordinator(
            currentVersion: current.flatMap(AppVersion.parse),
            checker: checker,
            bundleURL: URL(fileURLWithPath: "/tmp/Wiret.app")
        )
        coordinator.onUpdateAvailable = { [weak self] in self?.offered.append($0) }
        coordinator.onUpToDate = { [weak self] _ in self?.upToDateCount += 1 }
        coordinator.onError = { [weak self] in self?.errors.append($0) }
        return coordinator
    }

    // MARK: - 채널

    func testOffersNewerSnapshotToSnapshotBuild() {
        checker.releasesResult = .success([release("0.0.8-SNAPSHOT"), release("1.0.0")])
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")

        coordinator.check(userInitiated: true)

        XCTAssertEqual(offered.map(\.version.description), ["0.0.8-SNAPSHOT"])
    }

    func testOffersNewerReleaseToReleaseBuild() {
        checker.releasesResult = .success([release("0.0.8-SNAPSHOT"), release("1.1.0"), release("1.0.0")])
        let coordinator = makeCoordinator(current: "1.0.0")

        coordinator.check(userInitiated: true)

        XCTAssertEqual(offered.map(\.version.description), ["1.1.0"])
    }

    func testUpToDateIsReportedOnlyForManualChecks() {
        checker.releasesResult = .success([release("0.0.7-SNAPSHOT")])
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")

        coordinator.check(userInitiated: false)
        XCTAssertEqual(upToDateCount, 0, "자동 확인은 조용해야 합니다")

        coordinator.check(userInitiated: true)
        XCTAssertEqual(upToDateCount, 1)
    }

    // MARK: - 방해하지 않기

    /// 녹음 중에 업데이트 창을 띄우면 회의 녹음을 건드리게 된다.
    func testAutomaticCheckIsSkippedWhileBusy() {
        checker.releasesResult = .success([release("0.0.8-SNAPSHOT")])
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")
        coordinator.isBusyProvider = { true }

        coordinator.check(userInitiated: false)

        XCTAssertEqual(checker.fetchCount, 0)
        XCTAssertTrue(offered.isEmpty)
    }

    /// 직접 눌렀다면 녹음 중이어도 사용자가 의도한 것이다.
    func testManualCheckWorksWhileBusy() {
        checker.releasesResult = .success([release("0.0.8-SNAPSHOT")])
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")
        coordinator.isBusyProvider = { true }

        coordinator.check(userInitiated: true)

        XCTAssertEqual(offered.count, 1)
    }

    /// "나중에"를 눌렀는데 10초 뒤에 또 물으면 성가시다.
    func testPostponedVersionIsNotOfferedAgainAutomatically() {
        checker.releasesResult = .success([release("0.0.8-SNAPSHOT")])
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")
        coordinator.check(userInitiated: false)
        XCTAssertEqual(offered.count, 1)

        coordinator.postpone(offered[0])
        coordinator.check(userInitiated: false)

        XCTAssertEqual(offered.count, 1)
    }

    func testPostponedVersionIsStillOfferedWhenAskedManually() {
        checker.releasesResult = .success([release("0.0.8-SNAPSHOT")])
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")
        coordinator.check(userInitiated: false)
        coordinator.postpone(offered[0])

        coordinator.check(userInitiated: true)

        XCTAssertEqual(offered.count, 2)
    }

    /// 미룬 버전보다 더 새 버전이 나오면 다시 물어야 한다.
    func testNewerVersionIsOfferedEvenAfterPostponing() {
        checker.releasesResult = .success([release("0.0.8-SNAPSHOT")])
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")
        coordinator.check(userInitiated: false)
        coordinator.postpone(offered[0])

        checker.releasesResult = .success([release("0.0.8-SNAPSHOT"), release("0.0.9-SNAPSHOT")])
        coordinator.check(userInitiated: false)

        XCTAssertEqual(offered.map(\.version.description), ["0.0.8-SNAPSHOT", "0.0.9-SNAPSHOT"])
    }

    // MARK: - 로컬 빌드

    /// 버전 표시가 없으면 채널을 알 수 없다. 조용히 넘어가되, 직접 눌렀으면 이유를 알려 준다.
    func testLocalBuildDoesNotCheck() {
        let coordinator = makeCoordinator(current: nil)

        XCTAssertFalse(coordinator.canCheck)

        coordinator.check(userInitiated: false)
        XCTAssertEqual(checker.fetchCount, 0)
        XCTAssertTrue(errors.isEmpty)

        coordinator.check(userInitiated: true)
        XCTAssertEqual(checker.fetchCount, 0)
        XCTAssertEqual(errors.count, 1)
    }

    // MARK: - 오류

    func testNetworkErrorIsReportedOnlyForManualChecks() {
        checker.releasesResult = .failure(.network("끊김"))
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")

        coordinator.check(userInitiated: false)
        XCTAssertTrue(errors.isEmpty, "자동 확인 실패로 사용자를 방해하지 않습니다")

        coordinator.check(userInitiated: true)
        XCTAssertEqual(errors.count, 1)
    }

    func testDownloadFailureIsReported() {
        checker.downloadResult = .failure(.badResponse(404))
        let coordinator = makeCoordinator(current: "0.0.7-SNAPSHOT")

        coordinator.install(release("0.0.8-SNAPSHOT"))

        XCTAssertEqual(errors, [.badResponse(404)])
    }
}
