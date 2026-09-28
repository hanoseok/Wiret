import Foundation

/// 업데이트 확인부터 설치까지의 흐름을 관리한다.
///
/// 채널 규칙은 `AppUpdate.newestUpdate`가 지킨다. 여기서는 "언제 묻고, 언제 묻지 않는가"를 정한다.
final class UpdateCoordinator {
    /// 로컬 빌드 여부를 메뉴에 보여줄 수 있도록 외부에서도 읽는다.
    let currentVersion: AppVersion?
    private let checker: UpdateChecking
    private let installer: UpdateInstaller
    private let bundleURL: URL

    /// 녹음처럼 끊으면 안 되는 일이 진행 중인지. 그럴 때는 자동 확인이 말을 걸지 않는다.
    var isBusyProvider: (() -> Bool)?
    /// 누가 확인했는지 함께 넘긴다. 수동 확인은 메뉴 안에서 조용히 보여 주고, 자동 확인만 창을 띄워 묻는다.
    var onUpdateAvailable: ((ReleaseInfo, _ userInitiated: Bool) -> Void)?
    /// 수동 확인에서 최신일 때만 알린다. 자동 확인까지 알리면 조용해야 할 때 시끄럽다.
    var onUpToDate: ((AppVersion) -> Void)?
    /// 수동 확인이 실패했을 때만 알린다. 자동 확인 실패는 사용자가 기다린 게 아니니 조용히 넘어간다.
    var onCheckFailed: ((UpdateError) -> Void)?
    var onInstalled: ((ReleaseInfo) -> Void)?
    /// 설치(내려받기·교체) 실패. 확인 실패와 나눠야 받는 쪽이 메뉴 문구와 경고 창 중 어디로 보낼지 정할 수 있다.
    var onError: ((UpdateError) -> Void)?

    /// 사용자가 "나중에"를 누른 버전. 이 실행 동안에는 다시 묻지 않는다.
    private(set) var postponedVersions: Set<String> = []
    private(set) var isChecking = false
    /// 진행 중인 확인을 사용자가 기다리고 있는지.
    /// 자동 확인 도중에 사용자가 누르면 새로 묻지 않고 이 확인의 결과를 수동 확인처럼 돌려준다.
    /// 그러지 않으면 누른 쪽은 아무 답도 받지 못해 "확인 중"에 머문다.
    private var isUserWaiting = false

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
                onCheckFailed?(.versionMismatch(expected: "설치본", found: nil))
            }
            return
        }
        // 자동 확인은 녹음 중에 끼어들지 않는다. 수동으로 눌렀다면 사용자가 의도한 것이므로 진행한다.
        if !userInitiated, isBusyProvider?() == true { return }
        if isChecking {
            if userInitiated { isUserWaiting = true }
            return
        }
        isChecking = true
        isUserWaiting = userInitiated

        checker.fetchReleases { [weak self] result in
            guard let self else { return }
            let userInitiated = self.isUserWaiting
            self.isChecking = false
            self.isUserWaiting = false

            switch result {
            case .failure(let error):
                if userInitiated { self.onCheckFailed?(error) }
            case .success(let releases):
                guard let update = AppUpdate.newestUpdate(current: currentVersion, releases: releases) else {
                    if userInitiated { self.onUpToDate?(currentVersion) }
                    return
                }
                if !userInitiated, self.postponedVersions.contains(update.version.description) { return }
                if !userInitiated, self.isBusyProvider?() == true { return }
                self.onUpdateAvailable?(update, userInitiated)
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
