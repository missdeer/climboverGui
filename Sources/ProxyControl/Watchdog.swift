import Foundation
import Darwin

struct ControlBusy: LocalizedError {
    var errorDescription: String? { "另一个代理操作正在执行。" }
}

func runChild(sessionID: String, executable: String, arguments: [String]) throws {
    let identity = ManagedProcess.identity(getpid())
    guard !identity.isEmpty else { throw ControlError("无法确认待启动进程身份。") }
    for _ in 0..<200 {
        guard let data = try? Data(contentsOf: Runtime.state),
              let state = try? JSONDecoder().decode(SessionState.self, from: data),
              state.sessionID == sessionID, state.phase != .recovering else { return }
        if state.processes.contains(where: { $0.pid == getpid() && $0.identity == identity }) {
            // Only exec once the journal contains this PID. Its kernel birth identity stays the same.
            var argv = ([executable] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            execv(executable, &argv)
            throw ControlError("无法启动 \(executable)：\(String(cString: strerror(errno)))")
        }
        usleep(50_000)
    }
    throw ControlError("启动交接超时，代理未执行。")
}

func childProcesses(of pid: Int32) throws -> [ManagedProcess] {
    let output = try Command.run("/bin/ps", ["-ax", "-o", "pid=,ppid="]).output
    let pairs = output.split(separator: "\n").compactMap { line -> (Int32, Int32)? in
        let columns = line.split(whereSeparator: \.isWhitespace)
        guard columns.count == 2, let child = Int32(columns[0]), let parent = Int32(columns[1]) else { return nil }
        return (child, parent)
    }
    var descendants = Set<Int32>([pid])
    var previous = 0
    while previous != descendants.count {
        previous = descendants.count
        for (child, parent) in pairs where descendants.contains(parent) { descendants.insert(child) }
    }
    return descendants.filter { $0 != pid }.compactMap { child in
        let identity = ManagedProcess.identity(child)
        return identity.isEmpty ? nil : ManagedProcess(pid: child, identity: identity)
    }
}

func terminateManagedProcess(_ managed: ManagedProcess) throws {
    guard managed.alive else { return }
    // All new proxy children lead their own session; include their obfs-local child in termination.
    let target = getpgid(managed.pid) == managed.pid ? -managed.pid : managed.pid
    guard kill(target, SIGTERM) == 0 || errno == ESRCH else {
        throw ControlError("无法终止进程 \(managed.pid)：\(String(cString: strerror(errno)))")
    }
    for _ in 0..<20 {
        if !managed.alive { return }
        usleep(100_000)
    }
    if managed.alive, kill(target, SIGKILL) != 0, errno != ESRCH {
        throw ControlError("无法强制终止进程 \(managed.pid)。")
    }
}

func recordRecovery(_ message: String, completed: Bool) {
    do {
        let event = RecoveryEvent(date: Date(), message: message, completed: completed)
        try JSONEncoder().encode(event).write(to: Runtime.event, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Runtime.event.path)
    } catch { print("无法保存恢复提示：\(error.localizedDescription)") }
    print("\(Date()): \(message)")
    fflush(stdout)
}

func watch(sessionID: String) {
    var monitor = SessionMonitor()
    var finished = false
    while !finished {
        do {
            try locked(waitForMonitor: false) {
                guard fm.fileExists(atPath: Runtime.state.path) else { finished = true; return }
                let state = try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: Runtime.state))
                // A previous session's monitor must never stop a newer session.
                guard SessionMonitor.owns(state: state, sessionID: sessionID, pid: getpid()) else { finished = true; return }
                let health = HealthSnapshot(ownerAlive: state.owner.map(\.alive),
                    processesAlive: state.processes.map(\.alive), networkService: try? defaultService(),
                    companionsAlive: (state.companions ?? []).map(\.alive))
                guard let reason = monitor.reason(state: state, health: health) else {
                    try publishStatus(state, ready: true)
                    return
                }
                do {
                    try stop(reason: reason)
                    recordRecovery("\(reason)，已停止代理并恢复网络设置。", completed: true)
                    finished = true
                } catch {
                    recordRecovery("\(reason)，正在重试恢复：\(error.localizedDescription)", completed: false)
                }
            }
        } catch is ControlBusy {
            // Start/Stop/Switch owns the lock, including while the system resumes from sleep.
        } catch {
            recordRecovery("监控会话读取失败，将重试：\(error.localizedDescription)", completed: false)
        }
        if !finished { Thread.sleep(forTimeInterval: 2) }
    }
}
