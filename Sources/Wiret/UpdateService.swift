import Foundation

/// 지금 실행 중인 앱의 버전을 Info.plist에서 읽는다.
///
/// `WiretVersion`은 `build_app.sh`가 빌드할 때 써 넣는다. 이 키가 없으면 개발 중 로컬 빌드로
/// 보고 업데이트를 제안하지 않는다. 채널을 모르는 채로 갱신하면 스냅샷과 정식이 섞인다.
enum BundleVersion {
    static let versionKey = "WiretVersion"

    static func read(from info: [String: Any]?) -> AppVersion? {
        guard let text = info?[versionKey] as? String else { return nil }
        return AppVersion.parse(text)
    }

    static func current(bundle: Bundle = .main) -> AppVersion? {
        read(from: bundle.infoDictionary)
    }
}

enum UpdateError: LocalizedError, Equatable {
    case network(String)
    case badResponse(Int)
    case unpackFailed(String)
    case bundleMissing
    case versionMismatch(expected: String, found: String?)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .network(let message):
            return "업데이트 서버에 연결하지 못했습니다. (\(message))"
        case .badResponse(let code):
            return "업데이트 정보를 받지 못했습니다. (HTTP \(code))"
        case .unpackFailed(let message):
            return "내려받은 파일의 압축을 풀지 못했습니다. (\(message))"
        case .bundleMissing:
            return "내려받은 파일에서 Wiret.app을 찾지 못했습니다."
        case .versionMismatch(let expected, let found):
            return "내려받은 버전이 예상과 다릅니다. (기대 \(expected), 실제 \(found ?? "알 수 없음"))"
        case .replaceFailed(let message):
            return "앱을 교체하지 못했습니다. (\(message))"
        }
    }
}

protocol UpdateChecking: AnyObject {
    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateError>) -> Void)
    func download(_ release: ReleaseInfo, completion: @escaping (Result<URL, UpdateError>) -> Void)
}

/// GitHub Releases API로 새 버전을 찾고 내려받는다.
final class GitHubUpdateChecker: UpdateChecking {
    /// GitHub API가 요구하는 식별 문자열.
    static let userAgent = "Wiret-Updater"

    private let repository: String
    private let releasesURL: URL
    private let feedURL: URL
    private let session: URLSession

    init(
        repository: String = "hanoseok/Wiret",
        session: URLSession = .shared
    ) {
        self.repository = repository
        self.releasesURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
        self.feedURL = URL(string: "https://github.com/\(repository)/releases.atom")!
        self.session = session
    }

    func makeFeedRequest() -> URLRequest {
        var request = URLRequest(url: feedURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    /// GitHub API는 User-Agent 없는 요청을 403으로 거절한다. 요청 구성을 따로 떼어 테스트한다.
    func makeReleasesRequest() -> URLRequest {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        return request
    }

    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateError>) -> Void) {
        session.dataTask(with: makeReleasesRequest()) { [weak self] data, response, error in
            guard let self else { return }

            if error == nil,
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode),
               let data {
                let releases = AppUpdate.parseReleases(from: data)
                if !releases.isEmpty {
                    return completion(.success(releases))
                }
            }

            // 익명 API는 IP당 시간 60회라 회사망에서는 남의 호출로 먼저 소진되곤 한다.
            // 그때는 제한이 없는 Atom 피드로 한 번 더 시도한다.
            self.fetchReleasesFromFeed(completion: completion)
        }.resume()
    }

    private func fetchReleasesFromFeed(completion: @escaping (Result<[ReleaseInfo], UpdateError>) -> Void) {
        session.dataTask(with: makeFeedRequest()) { [repository] data, response, error in
            if let error {
                return completion(.failure(.network(error.localizedDescription)))
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return completion(.failure(.badResponse(http.statusCode)))
            }
            guard let data else {
                return completion(.failure(.network("빈 응답")))
            }
            completion(.success(AppUpdate.parseReleasesFeed(from: data, repository: repository)))
        }.resume()
    }

    func download(_ release: ReleaseInfo, completion: @escaping (Result<URL, UpdateError>) -> Void) {
        session.downloadTask(with: release.downloadURL) { location, response, error in
            if let error {
                return completion(.failure(.network(error.localizedDescription)))
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return completion(.failure(.badResponse(http.statusCode)))
            }
            guard let location else {
                return completion(.failure(.network("내려받은 파일이 없습니다")))
            }

            // 임시 파일은 이 클로저가 끝나면 사라지므로 옮겨 둔다.
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("WiretUpdate-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                return completion(.failure(.unpackFailed(error.localizedDescription)))
            }
            completion(.success(destination))
        }.resume()
    }
}

/// 내려받은 zip을 풀어 현재 앱 번들을 교체한다.
final class UpdateInstaller {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// zip을 풀고, 나온 앱이 기대한 버전인지 확인한 뒤 교체한다.
    func install(
        zip: URL,
        expecting version: AppVersion,
        replacing bundleURL: URL
    ) -> Result<Void, UpdateError> {
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("WiretUpdate-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: workspace) }

        do {
            try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        } catch {
            return .failure(.unpackFailed(error.localizedDescription))
        }

        if case .failure(let error) = unpack(zip: zip, into: workspace) {
            return .failure(error)
        }

        guard let newBundle = findAppBundle(in: workspace) else {
            return .failure(.bundleMissing)
        }

        // 내려받은 것이 정말 그 버전인지 확인한다. 엉뚱한 파일을 받아 앱을 덮어쓰면 복구가 어렵다.
        let found = bundleVersion(at: newBundle)
        guard found == version else {
            return .failure(.versionMismatch(expected: version.description, found: found?.description))
        }

        do {
            _ = try fileManager.replaceItemAt(bundleURL, withItemAt: newBundle)
        } catch {
            return .failure(.replaceFailed(error.localizedDescription))
        }
        return .success(())
    }

    func unpack(zip: URL, into directory: URL) -> Result<Void, UpdateError> {
        // ditto는 앱 번들의 심볼릭 링크와 확장 속성을 그대로 살려 푼다.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure(.unpackFailed(error.localizedDescription))
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.unpackFailed(message.isEmpty ? "ditto \(process.terminationStatus)" : message))
        }
        return .success(())
    }

    func findAppBundle(in directory: URL) -> URL? {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { $0.pathExtension == "app" }
    }

    func bundleVersion(at bundleURL: URL) -> AppVersion? {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = info as? [String: Any] else {
            return nil
        }
        return BundleVersion.read(from: dictionary)
    }
}
