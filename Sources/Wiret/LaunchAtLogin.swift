import ServiceManagement

/// 로그인 항목 등록 상태. `SMAppService.Status`를 그대로 쓰지 않는 것은 테스트에서 가짜로 바꿔 끼우기 위해서다.
enum LaunchAtLoginStatus: Equatable {
    case enabled
    case notRegistered
    /// 등록은 했지만 사용자가 시스템 설정에서 허용해야 실제로 실행된다.
    case requiresApproval
    case notFound
}

/// 로그인 시 실행 등록을 다룬다. 실제 구현은 이 Mac의 로그인 항목을 바꾸므로 테스트는 반드시 가짜를 쓴다.
protocol LaunchAtLoginControlling: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// `SMAppService.mainApp`으로 Wiret 자신을 로그인 항목에 등록한다.
///
/// `mainApp`은 지금 실행 중인 번들 자체를 등록하므로 따로 헬퍼 앱이나 LaunchAgent plist를 둘 필요가 없다.
/// 자동 업데이트는 같은 경로에서 번들을 교체하므로 업데이트한 뒤에도 등록이 그대로 남는다.
final class SystemLaunchAtLogin: LaunchAtLoginControlling {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
