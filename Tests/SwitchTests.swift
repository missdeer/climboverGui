import Foundation

private final class SwitchHarness {
    var active: String? = "old"
    var dns = "original"
    var failValidation = false
    var failCandidate = false
    var failRestore = false
    var failStopAt = 0
    var stops = 0
    var connects = 0
    var restores = 0

    func actions(candidate: String = "new", restore: Bool = true) -> SwitchActions {
        let snapshot = active
        return SwitchActions(validate: {
            if self.failValidation { throw ControlError("invalid config") }
        }, stop: {
            self.stops += 1
            if self.stops == self.failStopAt { throw ControlError("cleanup failed") }
            self.active = nil
            self.dns = "original"
        }, connect: {
            self.connects += 1
            self.active = candidate
            self.dns = "loopback"
            if self.failCandidate { throw ControlError("selected node unreachable") }
        }, restore: restore ? {
            self.restores += 1
            self.active = snapshot
            self.dns = "loopback"
            if self.failRestore { throw ControlError("old node unreachable") }
        } : nil)
    }
}

private func expectSwitchFailure(_ expected: SwitchFailureKind, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected switch failure") }
    catch let failure as SwitchFailure { require(failure.kind == expected, "Unexpected switch outcome: \(failure.message)") }
    catch { fatalError("Unexpected error: \(error)") }
}

func testSwitching() throws {
    let success = SwitchHarness()
    try ServerSwitch.run(previous: "old", actions: success.actions())
    require(success.active == "new" && success.restores == 0 && success.stops == 1, "Working node must be committed once")
    success.failCandidate = true
    expectSwitchFailure(.restored) { try ServerSwitch.run(previous: "new", actions: success.actions(candidate: "third")) }
    require(success.active == "new", "Sequential switches must restore the latest successful node")

    let invalid = SwitchHarness()
    invalid.failValidation = true
    expectSwitchFailure(.unchanged) { try ServerSwitch.run(previous: "old", actions: invalid.actions()) }
    require(invalid.active == "old" && invalid.stops == 0 && invalid.connects == 0, "Invalid configuration must not interrupt an existing connection")
    let rollback = SwitchHarness()
    rollback.failCandidate = true
    expectSwitchFailure(.restored) { try ServerSwitch.run(previous: "old", actions: rollback.actions()) }
    require(rollback.active == "old" && rollback.restores == 1 && rollback.dns == "loopback", "Unreachable node must restore previous connection")
    let bothFail = SwitchHarness()
    bothFail.failCandidate = true
    bothFail.failRestore = true
    expectSwitchFailure(.stopped) { try ServerSwitch.run(previous: "old", actions: bothFail.actions()) }
    require(bothFail.active == nil && bothFail.dns == "original" && bothFail.stops == 3, "Double failure must restore original DNS and stop all attempts")
    let cleanupFails = SwitchHarness()
    cleanupFails.failCandidate = true
    cleanupFails.failStopAt = 2
    expectSwitchFailure(.cleanupPending) { try ServerSwitch.run(previous: "old", actions: cleanupFails.actions()) }
    require(cleanupFails.restores == 0, "Never overwrite a session whose resources are still being cleaned up")
    let initialStopFails = SwitchHarness()
    initialStopFails.failStopAt = 1
    expectSwitchFailure(.cleanupPending) { try ServerSwitch.run(previous: "old", actions: initialStopFails.actions()) }
    require(initialStopFails.connects == 0 && initialStopFails.restores == 0, "Failed initial cleanup must block candidate startup")
    let firstStart = SwitchHarness()
    firstStart.active = nil
    firstStart.failCandidate = true
    expectSwitchFailure(.stopped) { try ServerSwitch.run(previous: nil, actions: firstStart.actions(restore: false)) }
    require(firstStart.active == nil && firstStart.dns == "original", "Initial connection failure must leave a clean stopped state")
    let acl = URL(fileURLWithPath: "/runtime/probe.acl")
    let oldFormat: [String: Any] = ["protocol": "redir", "local_port": 59097]
    let probed = ProbeConfiguration.addingListener(to: oldFormat, acl: acl)
    require(probed["local_port"] as? Int == 59097, "Legacy redir listener must be preserved")
    let idempotent = ProbeConfiguration.addingListener(to: probed, acl: acl)
    require((idempotent["locals"] as? [[String: Any]])?.count == 1, "Rollback must not duplicate the probe listener")
    let modern: [String: Any] = ["locals": [["protocol": "redir", "local_port": 59097]]]
    let modernProbed = ProbeConfiguration.addingListener(to: modern, acl: acl)
    let locals = modernProbed["locals"] as! [[String: Any]]
    require(locals.count == 2 && locals[0]["protocol"] as? String == "redir", "Modern redir listener must survive probe injection")
    require(locals[1]["acl"] as? String == acl.path && locals[1]["local_address"] as? String == "127.0.0.1", "Probe must force proxy use and listen only on loopback")
    print("PASS: successful/invalid/unreachable switches, rollback, double failure, cleanup failure, sequential switches")
    print("PASS: legacy/modern probe listeners, forced-proxy ACL, idempotent snapshot restoration")
    var dnsAttempts = 0
    var httpsAttempts = 0
    try ConnectionCheck.verify(resolve: {
        dnsAttempts += 1
        if dnsAttempts == 1 { throw ControlError("cold DNS timeout") }
        return true
    }, https: { _ in httpsAttempts += 1; return httpsAttempts == 2 })
    require(dnsAttempts == 2 && httpsAttempts == 2, "Cold DNS and one unavailable test site must not reject a working node")
    rejects("DNS probe failure") { try ConnectionCheck.verify(resolve: { false }, https: { _ in fatalError("HTTPS must wait for DNS readiness") }) }
    rejects("HTTPS proxy probe failure") { try ConnectionCheck.verify(resolve: { true }, https: { _ in false }) }
}
