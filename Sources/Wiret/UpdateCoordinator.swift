import Foundation

/// 업데이트 확인부터 설치까지의 흐름을 관리한다.
///
/// 채널 규칙은 `AppUpdate.newestUpdate`가 지킨다. 여기서는 "언제 묻고, 언제 묻지 않는가"를 정한다.
final class UpdateCoordinator {
    private let currentVersion: AppVersion?
    private let checker: UpdateChecking
    private let installer: UpdateInstaller
    private let bundleURL: URL

    /// 녹음처럼 끊으면 안 되는 일이 진행 중인지. 그럴 때는 자동 확인이 말을 걸지 않는다.
    var isBusyProvider: (() -> Bool)?
    var onUpdateAvailable: ((ReleaseInfo) -> Void)?
    /// 수동 확인에서 최신일 때만 알린다. 자동 확인까지 알리면 조용해야 할 때 시끄럽다.
    var onUpToDate: ((AppVersion) -> Void)?
    var onInstalled: ((ReleaseInfo) -> Void)?
    var onError: ((UpdateError) -> Void)?

    /// 사용자가 "나중에"를 누른 버전. 이 실행 동안에는 다시 묻지 않는다.
    private(set) var postponedVersions: Set<String> = []
    private(set) var isChecking = false

    init(
        currentVersion: AppVersion?,
        checker: UpdateChecking,
        installer: UpdateInstaller = UpdateInstaller(),
        bundleURL: URL
    ) {
        self.currentVersion = currentVersion
        self.checker = checker
        self.installer = installer
        self.bundleURL = bundleURL
    }

    /// 업데이트를 제안할 수 있는 상태인지. 버전 표시가 없는 로컬 빌드는 채널을 알 수 없어 제외한다.
    var canCheck: Bool {
        currentVersion != nil
    }

    func postpone(_ release: ReleaseInfo) {
        postponedVersions.insert(release.version.description)
    }

    func check(userInitiated: Bool) {
        guard let currentVersion else {
            // 로컬 빌드에서 수동으로 눌렀다면 아무 일도 없는 게 이상하니 알려 준다.
            if userInitiated {
                onError?(.versionMismatch(expected: "설치본", found: nil))
            }
            return
        }
        // 자동 확인은 녹음 중에 끼어들지 않는다. 수동으로 눌렀다면 사용자가 의도한 것이므로 진행한다.
        if !userInitiated, isBusyProvider?() == true { return }
        if isChecking { return }
        isChecking = true

        checker.fetchReleases { [weak self] result in
            guard let self else { return }
            self.isChecking = false

            switch result {
            case .failure(let error):
                if userInitiated { self.onError?(error) }
            case .success(let releases):
                guard let update = AppUpdate.newestUpdate(current: currentVersion, releases: releases) else {
                    if userInitiated { self.onUpToDate?(currentVersion) }
                    return
                }
                if !userInitiated, self.postponedVersions.contains(update.version.description) { return }
                if !userInitiated, self.isBusyProvider?() == true { return }
                self.onUpdateAvailable?(update)
            }
        }
    }

    func install(_ release: ReleaseInfo) {
        checker.download(release) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onError?(error)
            case .success(let zip):
                defer { try? FileManager.default.removeItem(at: zip) }
                switch self.installer.install(
                    zip: zip,
                    expecting: release.version,
                    replacing: self.bundleURL
                ) {
                case .success:
                    self.onInstalled?(release)
                case .failure(let error):
                    self.onError?(error)
                }
            }
        }
    }
}
