import Foundation

struct HealthSnapshot {
    var ownerAlive: Bool?
    var processesAlive: [Bool]
    var networkService: String?
    var companionsAlive: [Bool] = []
}

struct SessionMonitor {
    private var networkMismatchCount = 0

    static func owns(state: SessionState, sessionID: String, pid: Int32) -> Bool {
        state.sessionID == sessionID && (state.watchdog == nil || state.watchdog?.pid == pid)
    }

    mutating func reason(state: SessionState, health: HealthSnapshot) -> String? {
        if state.phase == .recovering { return state.recoveryReason ?? "继续恢复未完成的会话" }
        if state.phase != .ready { return "启动操作中断" }
        if health.ownerAlive == false { return "GUI 已意外退出" }
        if health.processesAlive.count != 2 { return "代理进程记录不完整" }
        if !health.processesAlive[0] { return "sslocal 已异常退出" }
        if !health.processesAlive[1] { return "CoreDNS 已异常退出" }
        if health.companionsAlive.contains(false) { return "代理插件已异常退出" }
        // A missing route during sleep or a short Wi-Fi reconnect is not itself a process failure.
        if let service = health.networkService, service != state.service {
            networkMismatchCount += 1
        } else { networkMismatchCount = 0 }
        if networkMismatchCount >= 2 { return "默认网络服务已切换" }
        return nil
    }
}

struct RecoveryActions {
    var readDNS: (String) throws -> [String]
    var writeDNS: (String, [String]) throws -> Void
    var flushPF: (String) throws -> Void
    var verifyPF: () throws -> Void
    var releasePF: (String) throws -> Void
    var terminate: (ManagedProcess) throws -> Void
    var checkpoint: (SessionState) throws -> Void
}

enum SessionRecovery {
    // Attempt DNS and PF independently, then detach resources only after both are confirmed safe.
    static func run(state: inout SessionState, actions: RecoveryActions) -> [String] {
        var failures: [String] = []
        func attempt(_ label: String, _ action: () throws -> Void) {
            do { try action() } catch { failures.append("\(label)：\(error.localizedDescription)") }
        }
        state.phase = .recovering
        attempt("保存恢复状态") { try actions.checkpoint(state) }
        if state.dnsChanged {
            attempt("恢复 DNS") {
                if try actions.readDNS(state.service) == ["127.0.0.1"] {
                    try actions.writeDNS(state.service, state.originalDNS)
                }
                state.dnsChanged = false
                try actions.checkpoint(state)
            }
        }
        var pfCleared = false
        attempt("清理并确认 PF 规则") {
            try PFVerification.clear(flush: actions.flushPF, verify: actions.verifyPF)
            pfCleared = true
        }
        guard pfCleared && !state.dnsChanged else { return failures }
        if let token = state.pfToken {
            attempt("释放 PF 令牌") {
                try actions.releasePF(token)
                state.pfToken = nil
                try actions.checkpoint(state)
            }
        }
        for process in (state.processes + (state.companions ?? [])).reversed() {
            attempt("停止进程 \(process.pid)") {
                try actions.terminate(process)
                state.processes.removeAll { $0.pid == process.pid && $0.identity == process.identity }
                state.companions?.removeAll { $0.pid == process.pid && $0.identity == process.identity }
                try actions.checkpoint(state)
            }
        }
        return failures
    }
}
