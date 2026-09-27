import Foundation

/// 업데이트 채널. 스냅샷은 스냅샷끼리, 정식은 정식끼리만 갱신한다.
enum UpdateChannel: String, Equatable {
    case snapshot
    case release
}

/// `0.0.8-SNAPSHOT`, `v1.2.3` 같은 버전 문자열.
struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let channel: UpdateChannel

    /// 앞의 `v`와 뒤의 `-SNAPSHOT`은 있어도 없어도 된다.
    static func parse(_ text: String) -> AppVersion? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }

        let suffix = "-SNAPSHOT"
        let channel: UpdateChannel
        if value.uppercased().hasSuffix(suffix) {
            channel = .snapshot
            value = String(value.dropLast(suffix.count))
        } else {
            channel = .release
        }

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            return nil
        }
        guard major >= 0, minor >= 0, patch >= 0 else { return nil }

        return AppVersion(major: major, minor: minor, patch: patch, channel: channel)
    }

    /// 숫자만 비교한다. 채널이 다른 버전끼리는 애초에 비교하지 않는다.
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return channel == .snapshot ? "\(base)-SNAPSHOT" : base
    }
}

/// 릴리스 하나에서 업데이트에 필요한 정보만 추린 것.
struct ReleaseInfo: Equatable {
    let version: AppVersion
    let downloadURL: URL
    /// 사람에게 보여줄 릴리스 페이지 주소.
    let pageURL: URL?
}

enum AppUpdate {
    /// 지금 버전보다 높은, **같은 채널**의 가장 높은 릴리스를 고른다.
    ///
    /// 채널을 섞지 않는 것이 이 기능의 핵심이다. 스냅샷을 쓰는 사람에게 정식 버전을 들이밀면
    /// 검증 중인 변경을 잃고, 정식 버전을 쓰는 사람에게 스냅샷을 주면 안정 버전이 아니게 된다.
    static func newestUpdate(current: AppVersion, releases: [ReleaseInfo]) -> ReleaseInfo? {
        releases
            .filter { $0.version.channel == current.channel }
            .filter { $0.version > current }
            .max { $0.version < $1.version }
    }

    /// 릴리스 페이지의 Atom 피드에서 릴리스 목록을 뽑는다.
    ///
    /// 익명 GitHub API는 IP당 시간 60회로 묶여 있어, 회사망처럼 여러 사람이 같은 공인 IP를 쓰면
    /// 남의 호출 때문에 403이 난다. 피드(`github.com/.../releases.atom`)는 그 제한을 받지 않아
    /// API가 막혔을 때 쓸 수 있다.
    ///
    /// 피드에는 자산 목록이 없으므로 내려받을 주소를 CI의 이름 규칙에서 만든다. 잘못 짚어도
    /// 설치 직전 `WiretVersion` 확인에서 걸러지므로 엉뚱한 앱으로 덮어쓰지는 않는다.
    static func parseReleasesFeed(from data: Data, repository: String) -> [ReleaseInfo] {
        let text = String(decoding: data, as: UTF8.self)
        let marker = "/releases/tag/"

        var tags: [String] = []
        var cursor = text.startIndex
        while let range = text.range(of: marker, range: cursor..<text.endIndex) {
            cursor = range.upperBound
            // href="..." 안이므로 따옴표 전까지가 태그다.
            guard let end = text[cursor...].firstIndex(where: { $0 == "\"" || $0 == "<" }) else { break }
            let tag = String(text[cursor..<end])
            if !tag.isEmpty, !tags.contains(tag) {
                tags.append(tag)
            }
        }

        return tags.compactMap { tag -> ReleaseInfo? in
            guard let version = AppVersion.parse(tag) else { return nil }
            let asset = "Wiret-\(version).zip"
            guard let download = URL(
                string: "https://github.com/\(repository)/releases/download/\(tag)/\(asset)"
            ) else { return nil }
            return ReleaseInfo(
                version: version,
                downloadURL: download,
                pageURL: URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")
            )
        }
    }

    /// GitHub Releases API 응답에서 릴리스 목록을 뽑는다.
    ///
    /// 태그에서 버전을 읽고, 자산 중 `.zip` 하나를 내려받을 대상으로 삼는다.
    /// 버전을 못 읽거나 zip이 없는 릴리스는 건너뛴다.
    static func parseReleases(from data: Data) -> [ReleaseInfo] {
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let entries = raw as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry -> ReleaseInfo? in
            guard let tag = entry["tag_name"] as? String,
                  let version = AppVersion.parse(tag) else {
                return nil
            }
            // 초안(draft)은 공개되지 않은 릴리스다.
            if entry["draft"] as? Bool == true { return nil }

            let assets = entry["assets"] as? [[String: Any]] ?? []
            let zipURL = assets
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(".zip") }
            guard let zipURL, let downloadURL = URL(string: zipURL) else { return nil }

            let page = (entry["html_url"] as? String).flatMap(URL.init(string:))
            return ReleaseInfo(version: version, downloadURL: downloadURL, pageURL: page)
        }
    }
}
