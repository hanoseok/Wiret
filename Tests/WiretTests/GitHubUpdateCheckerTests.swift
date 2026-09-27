import XCTest
@testable import Wiret

/// 네트워크를 타지 않고 응답을 흉내내는 스텁.
private final class StubURLProtocol: URLProtocol {
    /// URL에 이 문자열이 들어 있으면 해당 응답을 준다.
    static var responses: [(match: String, status: Int, body: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        let match = Self.responses.first { url.contains($0.match) }

        guard let match else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: match.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class GitHubUpdateCheckerTests: XCTestCase {
    private var session: URLSession!

    private static let apiBody = Data("""
    [{"tag_name": "v0.0.8-SNAPSHOT", "draft": false,
      "assets": [{"browser_download_url": "https://example.com/Wiret-0.0.8-SNAPSHOT.zip"}]}]
    """.utf8)

    private static let feedBody = Data("""
    <feed><entry>
      <link rel="alternate" href="https://github.com/hanoseok/Wiret/releases/tag/v0.0.9-SNAPSHOT"/>
    </entry></feed>
    """.utf8)

    override func setUp() {
        super.setUp()
        StubURLProtocol.responses = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.responses = []
        session = nil
        super.tearDown()
    }

    private func fetch(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<[ReleaseInfo], UpdateError>? {
        let expectation = expectation(description: "fetchReleases")
        var captured: Result<[ReleaseInfo], UpdateError>?

        // 일부러 체커를 변수에 담지 않는다. 호출한 쪽이 붙들고 있지 않아도 완료는 불려야 한다.
        GitHubUpdateChecker(repository: "hanoseok/Wiret", session: session).fetchReleases { result in
            captured = result
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: timeout)
        return captured
    }

    /// 체커를 약하게 잡으면 요청이 끝나기 전에 해제되어 완료가 아예 불리지 않는다.
    /// 기다리는 쪽은 영영 멈춘다. 실제로 겪은 문제라 테스트로 묶어 둔다.
    func testCompletionFiresEvenWhenCallerDoesNotRetainTheChecker() throws {
        StubURLProtocol.responses = [("api.github.com", 200, Self.apiBody)]

        let result = try XCTUnwrap(fetch())

        XCTAssertEqual(try result.get().map(\.version.description), ["0.0.8-SNAPSHOT"])
    }

    /// 익명 API는 IP당 시간 60회라 공용 IP에서는 남의 호출로 먼저 소진된다.
    func testFallsBackToFeedWhenApiIsRateLimited() throws {
        StubURLProtocol.responses = [
            ("api.github.com", 403, Data("{\"message\":\"rate limit\"}".utf8)),
            ("releases.atom", 200, Self.feedBody)
        ]

        let result = try XCTUnwrap(fetch())

        XCTAssertEqual(try result.get().map(\.version.description), ["0.0.9-SNAPSHOT"])
    }

    func testUsesApiWhenItWorks() throws {
        StubURLProtocol.responses = [
            ("api.github.com", 200, Self.apiBody),
            ("releases.atom", 200, Self.feedBody)
        ]

        let result = try XCTUnwrap(fetch())

        XCTAssertEqual(try result.get().map(\.version.description), ["0.0.8-SNAPSHOT"])
    }

    /// 둘 다 막히면 오류를 돌려줘야 한다. 조용히 사라지면 수동 확인이 먹통으로 보인다.
    func testReportsErrorWhenBothSourcesFail() throws {
        StubURLProtocol.responses = [
            ("api.github.com", 500, Data()),
            ("releases.atom", 503, Data())
        ]

        let result = try XCTUnwrap(fetch())

        guard case .failure(.badResponse(503)) = result else {
            return XCTFail("503 오류를 기대했지만 \(result)")
        }
    }
}
