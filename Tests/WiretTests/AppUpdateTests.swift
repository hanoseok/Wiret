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

final class AppUpdateFeedParsingTests: XCTestCase {
    /// 실제 releases.atom 과 같은 모양.
    private let feed = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <id>tag:github.com,2008:https://github.com/hanoseok/Wiret/releases</id>
      <link type="text/html" rel="alternate" href="https://github.com/hanoseok/Wiret/releases"/>
      <entry>
        <id>tag:github.com,2008:Repository/1/v0.0.8-SNAPSHOT</id>
        <link rel="alternate" type="text/html" href="https://github.com/hanoseok/Wiret/releases/tag/v0.0.8-SNAPSHOT"/>
        <title>Wiret 0.0.8-SNAPSHOT</title>
      </entry>
      <entry>
        <id>tag:github.com,2008:Repository/1/snapshot-latest</id>
        <link rel="alternate" type="text/html" href="https://github.com/hanoseok/Wiret/releases/tag/snapshot-latest"/>
        <title>최신 스냅샷 (0.0.8-SNAPSHOT)</title>
      </entry>
      <entry>
        <id>tag:github.com,2008:Repository/1/v1.0.0</id>
        <link rel="alternate" type="text/html" href="https://github.com/hanoseok/Wiret/releases/tag/v1.0.0"/>
        <title>Wiret 1.0.0</title>
      </entry>
    </feed>
    """.utf8)

    func testParsesVersionsFromFeed() {
        let releases = AppUpdate.parseReleasesFeed(from: feed, repository: "hanoseok/Wiret")

        XCTAssertEqual(releases.map(\.version.description), ["0.0.8-SNAPSHOT", "1.0.0"])
    }

    /// 피드에는 자산 목록이 없어 CI 이름 규칙으로 주소를 만든다.
    /// 규칙이 바뀌면 여기서 먼저 깨져야 한다.
    func testDerivesDownloadURLFromNamingConvention() {
        let releases = AppUpdate.parseReleasesFeed(from: feed, repository: "hanoseok/Wiret")

        XCTAssertEqual(
            releases.first?.downloadURL.absoluteString,
            "https://github.com/hanoseok/Wiret/releases/download/v0.0.8-SNAPSHOT/Wiret-0.0.8-SNAPSHOT.zip"
        )
        XCTAssertEqual(
            releases.last?.downloadURL.absoluteString,
            "https://github.com/hanoseok/Wiret/releases/download/v1.0.0/Wiret-1.0.0.zip"
        )
    }

    /// snapshot-latest 는 버전별 릴리스와 같은 빌드를 가리키는 별칭이라 세면 중복이 된다.
    func testSkipsNonVersionTags() {
        let releases = AppUpdate.parseReleasesFeed(from: feed, repository: "hanoseok/Wiret")

        XCTAssertFalse(releases.contains { $0.downloadURL.absoluteString.contains("snapshot-latest") })
    }

    func testEmptyFeedYieldsNothing() {
        XCTAssertTrue(AppUpdate.parseReleasesFeed(from: Data(), repository: "a/b").isEmpty)
        XCTAssertTrue(AppUpdate.parseReleasesFeed(from: Data("<feed/>".utf8), repository: "a/b").isEmpty)
    }
}
