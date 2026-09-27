import XCTest
@testable import Wiret

final class BundleVersionTests: XCTestCase {
    func testReadsWiretVersionKey() {
        let version = BundleVersion.read(from: ["WiretVersion": "0.0.8-SNAPSHOT"])

        XCTAssertEqual(version, AppVersion.parse("0.0.8-SNAPSHOT"))
    }

    /// 표시가 없으면 개발 중 로컬 빌드다. 채널을 모르는 채로 갱신하면 스냅샷과 정식이 섞인다.
    func testMissingKeyMeansNoVersion() {
        XCTAssertNil(BundleVersion.read(from: [:]))
        XCTAssertNil(BundleVersion.read(from: nil))
        XCTAssertNil(BundleVersion.read(from: ["CFBundleShortVersionString": "1.0.0"]))
    }

    func testMalformedValueMeansNoVersion() {
        XCTAssertNil(BundleVersion.read(from: ["WiretVersion": "어쩌구"]))
    }
}

final class UpdateInstallerTests: XCTestCase {
    private var root: URL!
    private let installer = UpdateInstaller()

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateInstallerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// 실제 앱 번들 모양(Contents/Info.plist + 실행 파일)을 만든다.
    @discardableResult
    private func makeBundle(at url: URL, version: String?, marker: String = "old") throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: macOS.appendingPathComponent("Wiret"))

        var info: [String: Any] = ["CFBundleName": "Wiret"]
        if let version {
            info["WiretVersion"] = version
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    private func makeZip(of bundle: URL, named name: String) throws -> URL {
        let zip = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, zip.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "테스트용 zip 생성 실패")
        return zip
    }

    private func version(_ text: String) -> AppVersion {
        AppVersion.parse(text)!
    }

    // MARK: - 압축 해제와 검사

    func testUnpackAndFindBundle() throws {
        let source = try makeBundle(at: root.appendingPathComponent("src/Wiret.app"), version: "0.0.8-SNAPSHOT")
        let zip = try makeZip(of: source, named: "new.zip")
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let result = installer.unpack(zip: zip, into: out)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(installer.findAppBundle(in: out)?.lastPathComponent, "Wiret.app")
    }

    func testBundleVersionIsReadFromInfoPlist() throws {
        let bundle = try makeBundle(at: root.appendingPathComponent("Wiret.app"), version: "1.2.3")

        XCTAssertEqual(installer.bundleVersion(at: bundle), version("1.2.3"))
    }

    func testUnpackFailsOnGarbage() throws {
        let fake = root.appendingPathComponent("broken.zip")
        try Data("not a zip".utf8).write(to: fake)
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        guard case .failure(.unpackFailed) = installer.unpack(zip: fake, into: out) else {
            return XCTFail("압축 해제 실패를 기대했습니다")
        }
    }

    // MARK: - 교체

    func testInstallReplacesTheRunningBundle() throws {
        let installed = try makeBundle(at: root.appendingPathComponent("Wiret.app"), version: "0.0.7-SNAPSHOT", marker: "old")
        let staged = try makeBundle(at: root.appendingPathComponent("src/Wiret.app"), version: "0.0.8-SNAPSHOT", marker: "new")
        let zip = try makeZip(of: staged, named: "new.zip")

        let result = installer.install(zip: zip, expecting: version("0.0.8-SNAPSHOT"), replacing: installed)

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(installer.bundleVersion(at: installed), version("0.0.8-SNAPSHOT"))
        let executable = try Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/Wiret"))
        XCTAssertEqual(String(decoding: executable, as: UTF8.self), "new")
    }

    /// 엉뚱한 파일을 받아 앱을 덮어쓰면 복구가 어렵다. 버전이 다르면 교체하지 않는다.
    func testInstallRefusesWhenDownloadedVersionDiffers() throws {
        let installed = try makeBundle(at: root.appendingPathComponent("Wiret.app"), version: "0.0.7-SNAPSHOT", marker: "old")
        let staged = try makeBundle(at: root.appendingPathComponent("src/Wiret.app"), version: "0.0.9-SNAPSHOT", marker: "new")
        let zip = try makeZip(of: staged, named: "new.zip")

        let result = installer.install(zip: zip, expecting: version("0.0.8-SNAPSHOT"), replacing: installed)

        guard case .failure(.versionMismatch) = result else {
            return XCTFail("버전 불일치를 기대했지만 \(result)")
        }
        // 기존 앱은 그대로 남아 있어야 한다.
        XCTAssertEqual(installer.bundleVersion(at: installed), version("0.0.7-SNAPSHOT"))
        let executable = try Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/Wiret"))
        XCTAssertEqual(String(decoding: executable, as: UTF8.self), "old")
    }

    func testInstallRefusesWhenVersionMarkerIsMissing() throws {
        let installed = try makeBundle(at: root.appendingPathComponent("Wiret.app"), version: "0.0.7-SNAPSHOT", marker: "old")
        let staged = try makeBundle(at: root.appendingPathComponent("src/Wiret.app"), version: nil, marker: "new")
        let zip = try makeZip(of: staged, named: "new.zip")

        let result = installer.install(zip: zip, expecting: version("0.0.8-SNAPSHOT"), replacing: installed)

        guard case .failure(.versionMismatch) = result else {
            return XCTFail("버전 불일치를 기대했지만 \(result)")
        }
        XCTAssertEqual(installer.bundleVersion(at: installed), version("0.0.7-SNAPSHOT"))
    }

    func testInstallReportsMissingBundle() throws {
        // 앱 번들이 아닌 파일만 담긴 zip
        let stray = root.appendingPathComponent("src/readme.txt")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: stray)
        let zip = try makeZip(of: stray, named: "new.zip")
        let installed = try makeBundle(at: root.appendingPathComponent("Wiret.app"), version: "0.0.7-SNAPSHOT")

        let result = installer.install(zip: zip, expecting: version("0.0.8-SNAPSHOT"), replacing: installed)

        guard case .failure(.bundleMissing) = result else {
            return XCTFail("번들 없음을 기대했지만 \(result)")
        }
    }
}

final class GitHubUpdateCheckerRequestTests: XCTestCase {
    /// GitHub API는 User-Agent 없는 요청을 403으로 거절한다. 실제로 겪은 문제라 테스트로 묶어 둔다.
    func testReleasesRequestCarriesUserAgent() {
        let request = GitHubUpdateChecker().makeReleasesRequest()

        let userAgent = request.value(forHTTPHeaderField: "User-Agent")
        XCTAssertNotNil(userAgent)
        XCTAssertFalse(userAgent?.isEmpty ?? true)
    }

    func testReleasesRequestAsksForTheReleasesEndpoint() {
        let request = GitHubUpdateChecker(repository: "hanoseok/Wiret").makeReleasesRequest()

        let url = request.url?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("https://api.github.com/repos/hanoseok/Wiret/releases"), url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }
}
