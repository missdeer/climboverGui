import Foundation

func testRecovery() throws {
    var state = SessionState(profile: "test.conf", service: "Wi-Fi", originalDNS: ["192.0.2.53"])
    state.processes = [ManagedProcess(pid: 101, identity: "proxy"), ManagedProcess(pid: 102, identity: "dns")]
    state.companions = [ManagedProcess(pid: 103, identity: "plugin")]
    state.phase = .ready
    state.sessionID = "new-session"
    state.watchdog = ManagedProcess(pid: 104, identity: "watchdog")
    state.pfToken = "own-token"
    state.dnsChanged = true
    let now = Date()
    var status = PublicStatus(profile: state.profile, service: state.service, processes: state.processes,
        ready: true, watchdog: state.watchdog, lastChecked: now)
    require(status.healthy(at: now), "GUI must consume the root monitor's verified heartbeat")
    require(!status.healthy(at: now.addingTimeInterval(13)), "A stopped monitor must become unhealthy")
    status.ready = false
    require(!status.healthy(at: now), "Recovery/startup must not show a connected status")
    require(!SessionMonitor.owns(state: state, sessionID: "old-session", pid: 104), "Stale monitor must not touch a newer session")
    require(!SessionMonitor.owns(state: state, sessionID: "new-session", pid: 105), "Another monitor must not adopt an active session")
    require(SessionMonitor.owns(state: state, sessionID: "new-session", pid: 104), "Current monitor must own its session")
    var monitor = SessionMonitor()
    var health = HealthSnapshot(ownerAlive: true, processesAlive: [true, true], networkService: "Wi-Fi")
    require(monitor.reason(state: state, health: health) == nil, "Healthy session must stay connected")
    health.ownerAlive = false
    require(monitor.reason(state: state, health: health) != nil, "GUI crash must trigger recovery")
    health.ownerAlive = nil
    health.processesAlive = [false, true]
    require(monitor.reason(state: state, health: health) != nil, "Proxy crash must trigger recovery for CLI sessions too")
    health.processesAlive = [true, false]
    require(monitor.reason(state: state, health: health) != nil, "DNS crash must trigger recovery")
    health.processesAlive = [true, true]
    health.networkService = nil
    for _ in 0..<10 { require(monitor.reason(state: state, health: health) == nil, "Sleep or missing route must not look like a crash") }
    health.networkService = "Ethernet"
    require(monitor.reason(state: state, health: health) == nil, "One routing transition must be tolerated")
    require(monitor.reason(state: state, health: health) != nil, "Stable default service change must restore old network settings")
    health.networkService = "Wi-Fi"
    require(monitor.reason(state: state, health: health) == nil, "Wake on original service remains healthy")

    var writes: [[String]] = []
    var flushed: [String] = []
    var released: [String] = []
    var terminated: [Int32] = []
    var checkpoints: [SessionState] = []
    var failDNS = true
    var failPF = true
    var actions = RecoveryActions(readDNS: { _ in ["127.0.0.1"] }, writeDNS: { _, servers in
        if failDNS { throw ControlError("simulated DNS failure") }
        writes.append(servers)
    }, flushPF: { kind in
        flushed.append(kind)
        if failPF && kind == "rules" { throw ControlError("simulated PF failure") }
    }, verifyPF: {
        if failPF { throw ControlError("simulated PF residual rules") }
    }, releasePF: { released.append($0) }, terminate: { terminated.append($0.pid) }, checkpoint: { checkpoints.append($0) })
    let failures = SessionRecovery.run(state: &state, actions: actions)
    require(failures.count == 2, "Both independent failures must be reported")
    require(flushed == ["nat", "rules", "Tables"], "PF failure must not skip remaining tables")
    require(terminated.isEmpty, "Keep proxy/DNS processes while unconfirmed routing may still depend on them")
    require(state.dnsChanged && state.pfToken != nil && released.isEmpty && state.processes.count == 2,
        "Failed PF/DNS restoration must retain resources and the recovery journal")
    require(checkpoints.first?.phase == .recovering, "Crash during recovery must leave a recoverable phase")
    failDNS = false
    failPF = false
    require(SessionRecovery.run(state: &state, actions: actions).isEmpty, "Retry must finish remaining recovery")
    require(writes == [["192.0.2.53"]] && released == ["own-token"], "Retry must restore original DNS without releasing a token twice")
    require(Set(terminated) == [101, 102, 103] && !state.dnsChanged, "All dependent processes must be cleaned after successful restoration")

    state.dnsChanged = true
    actions.readDNS = { _ in ["192.0.2.99"] }
    require(SessionRecovery.run(state: &state, actions: actions).isEmpty && writes.count == 1,
        "DNS changed by another app must be preserved")
    state.dnsChanged = true
    state.originalDNS = []
    actions.readDNS = { _ in ["127.0.0.1"] }
    _ = SessionRecovery.run(state: &state, actions: actions)
    require(writes.last == [], "Automatic DNS must be restored as automatic")
    state.processes = [ManagedProcess(pid: 201, identity: "old PID identity")]
    actions.terminate = { _ in throw ControlError("simulated termination failure") }
    require(!SessionRecovery.run(state: &state, actions: actions).isEmpty && state.processes.count == 1,
        "Failed termination must stay recorded for retry")
    let legacy = Data(#"{"profile":"old.conf","service":"Wi-Fi","originalDNS":[],"processes":[],"dnsChanged":false}"#.utf8)
    let decoded = try JSONDecoder().decode(SessionState.self, from: legacy)
    require(decoded.sessionID == nil && decoded.watchdog == nil, "Old active sessions must remain stoppable after upgrade")
    print("PASS: crash detection, stale sessions, sleep/wake and network transition policy")
    print("PASS: independent cleanup, retry journal, plugin cleanup, DNS ownership, legacy sessions")
}
