import XCTest
@testable import Wiret

final class AppVersionTests: XCTestCase {
    func testParsesPlainVersion() {
        let version = AppVersion.parse("1.2.3")

        XCTAssertEqual(version, AppVersion(major: 1, minor: 2, patch: 3, channel: .release))
    }

    func testParsesSnapshotVersion() {
        let version = AppVersion.parse("0.0.8-SNAPSHOT")

        XCTAssertEqual(version, AppVersion(major: 0, minor: 0, patch: 8, channel: .snapshot))
    }

    func testParsesTagWithLeadingV() {
        XCTAssertEqual(AppVersion.parse("v0.0.8-SNAPSHOT")?.channel, .snapshot)
        XCTAssertEqual(AppVersion.parse("v1.0.0")?.channel, .release)
    }

    func testRejectsMalformedVersions() {
        XCTAssertNil(AppVersion.parse(""))
        XCTAssertNil(AppVersion.parse("1.2"))
        XCTAssertNil(AppVersion.parse("1.2.3.4"))
        XCTAssertNil(AppVersion.parse("snapshot"))
        XCTAssertNil(AppVersion.parse("v1.2.x"))
    }

    func testOrdersByNumber() {
        XCTAssertLessThan(AppVersion.parse("0.0.9")!, AppVersion.parse("0.1.0")!)
        XCTAssertLessThan(AppVersion.parse("0.9.9")!, AppVersion.parse("1.0.0")!)
        // 문자열 비교였다면 "0.0.10" < "0.0.9" 가 됐을 것이다.
        XCTAssertLessThan(AppVersion.parse("0.0.9")!, AppVersion.parse("0.0.10")!)
    }

    func testDescriptionRoundTrips() {
        XCTAssertEqual(AppVersion.parse("0.0.8-SNAPSHOT")?.description, "0.0.8-SNAPSHOT")
        XCTAssertEqual(AppVersion.parse("v1.2.3")?.description, "1.2.3")
    }
}

final class AppUpdateDecisionTests: XCTestCase {
    private func release(_ tag: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion.parse(tag)!,
            downloadURL: URL(string: "https://example.com/\(tag).zip")!,
            pageURL: nil
        )
    }

    private func version(_ text: String) -> AppVersion {
        AppVersion.parse(text)!
    }

    func testPicksHighestNewerSnapshotForSnapshotBuild() {
        let update = AppUpdate.newestUpdate(
            current: version("0.0.7-SNAPSHOT"),
            releases: [release("0.0.8-SNAPSHOT"), release("0.0.10-SNAPSHOT"), release("0.0.9-SNAPSHOT")]
        )

        XCTAssertEqual(update?.version, version("0.0.10-SNAPSHOT"))
    }

    /// 스냅샷 사용자에게 정식 버전을 주면 검증 중인 변경을 잃는다.
    func testSnapshotBuildIgnoresReleaseVersions() {
        let update = AppUpdate.newestUpdate(
            current: version("0.0.7-SNAPSHOT"),
            releases: [release("1.0.0"), release("2.0.0")]
        )

        XCTAssertNil(update)
    }

    /// 정식 버전 사용자에게 스냅샷을 주면 안정 버전이 아니게 된다.
    func testReleaseBuildIgnoresSnapshotVersions() {
        let update = AppUpdate.newestUpdate(
            current: version("1.0.0"),
            releases: [release("1.0.1-SNAPSHOT"), release("2.0.0-SNAPSHOT")]
        )

        XCTAssertNil(update)
    }

    func testReleaseBuildPicksHighestRelease() {
        let update = AppUpdate.newestUpdate(
            current: version("1.0.0"),
            releases: [release("1.0.1"), release("1.2.0"), release("1.0.5-SNAPSHOT")]
        )

        XCTAssertEqual(update?.version, version("1.2.0"))
    }

    func testSameVersionIsNotAnUpdate() {
        XCTAssertNil(AppUpdate.newestUpdate(
            current: version("0.0.7-SNAPSHOT"),
            releases: [release("0.0.7-SNAPSHOT")]
        ))
    }

    func testOlderVersionIsNotAnUpdate() {
        XCTAssertNil(AppUpdate.newestUpdate(
            current: version("0.0.7-SNAPSHOT"),
            releases: [release("0.0.6-SNAPSHOT")]
        ))
    }

    func testNoReleasesMeansNoUpdate() {
        XCTAssertNil(AppUpdate.newestUpdate(current: version("1.0.0"), releases: []))
    }
}

final class AppUpdateReleaseParsingTests: XCTestCase {
    private func json(_ text: String) -> Data {
        Data(text.utf8)
    }

    func testParsesTagAndZipAsset() {
        let data = json("""
        [{
          "tag_name": "v0.0.8-SNAPSHOT",
          "draft": false,
          "prerelease": true,
          "html_url": "https://github.com/hanoseok/Wiret/releases/tag/v0.0.8-SNAPSHOT",
          "assets": [{"browser_download_url": "https://example.com/Wiret-0.0.8-SNAPSHOT.zip"}]
        }]
        """)

        let releases = AppUpdate.parseReleases(from: data)

        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].version, AppVersion.parse("0.0.8-SNAPSHOT"))
        XCTAssertEqual(releases[0].downloadURL.lastPathComponent, "Wiret-0.0.8-SNAPSHOT.zip")
        XCTAssertNotNil(releases[0].pageURL)
    }

    /// snapshot-latest 처럼 버전으로 읽을 수 없는 태그는 건너뛴다.
    /// 이 태그는 버전별 릴리스와 같은 빌드를 가리키는 별칭이라, 세면 중복이 된다.
    func testSkipsTagsThatAreNotVersions() {
        let data = json("""
        [
          {"tag_name": "snapshot-latest", "assets": [{"browser_download_url": "https://example.com/a.zip"}]},
          {"tag_name": "v0.0.8-SNAPSHOT", "assets": [{"browser_download_url": "https://example.com/b.zip"}]}
        ]
        """)

        let releases = AppUpdate.parseReleases(from: data)

        XCTAssertEqual(releases.map(\.version.description), ["0.0.8-SNAPSHOT"])
    }

    func testSkipsReleasesWithoutZipAsset() {
        let data = json("""
        [{"tag_name": "v1.0.0", "assets": [{"browser_download_url": "https://example.com/notes.txt"}]}]
        """)

        XCTAssertTrue(AppUpdate.parseReleases(from: data).isEmpty)
    }

    func testSkipsDrafts() {
        let data = json("""
        [{"tag_name": "v1.0.0", "draft": true,
          "assets": [{"browser_download_url": "https://example.com/a.zip"}]}]
        """)

        XCTAssertTrue(AppUpdate.parseReleases(from: data).isEmpty)
    }

    func testMalformedJSONYieldsNothing() {
        XCTAssertTrue(AppUpdate.parseReleases(from: json("not json")).isEmpty)
        XCTAssertTrue(AppUpdate.parseReleases(from: json("{}")).isEmpty)
    }
}
