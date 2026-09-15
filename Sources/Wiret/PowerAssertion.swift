import Foundation
import IOKit.pwr_mgt

/// Keeps the system awake while an auto recording is imminent or in progress.
protocol SleepPreventing: AnyObject {
    var isActive: Bool { get }
    func activate(reason: String)
    func release()
}

final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var isActive = false

    func activate(reason: String) {
        if isActive { return }
        var newId: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newId
        )
        guard result == kIOReturnSuccess else { return }
        id = newId
        isActive = true
    }

    func release() {
        guard isActive else { return }
        _ = IOPMAssertionRelease(id)
        id = 0
        isActive = false
    }

    deinit {
        release()
    }
}

extension PowerAssertion: SleepPreventing {}
