import MarginKit
import ServiceManagement
import Testing

@Suite struct LoginItemTests {
    @Test func stateFollowsServiceStatus() {
        #expect(LoginItem.State(.enabled) == .on)
        #expect(LoginItem.State(.requiresApproval) == .needsApproval)
        #expect(LoginItem.State(.notRegistered) == .off)
        #expect(LoginItem.State(.notFound) == .off)
    }

    /// The toggle shows "on" while approval is pending, so turning it off is still possible.
    @Test func toggleIsOnUnlessOff() {
        #expect(LoginItem.State.on.isOn)
        #expect(LoginItem.State.needsApproval.isOn)
        #expect(!LoginItem.State.off.isOn)
    }
}
