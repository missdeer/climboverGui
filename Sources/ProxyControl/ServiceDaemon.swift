import Foundation
import Darwin

private let serviceQueue = DispatchQueue(label: "com.dfordsoft.climbover.requests", qos: .userInitiated, attributes: .concurrent)
// Read/write only while holding the cross-process operation lock.
private var serviceUpdating = false

final class ServiceEndpoint: NSObject, ProxyServiceProtocol {
    let owner: ManagedProcess
    init(owner: ManagedProcess) { self.owner = owner }

    func perform(_ operation: String, profile: String, service: String, additionalCIDRs: String, reply: @escaping (Data?, String?) -> Void) {
        serviceQueue.async {
            do {
                try ServiceRequest.validate(operation, profile: profile, service: service, additionalCIDRs: additionalCIDRs)
                guard self.owner.alive else { throw ControlError("调用应用已退出。") }
                let data = try locked {
                    try ensureRuntimeDirectory()
                    switch operation {
                    case "start":
                        guard !serviceUpdating else { throw ControlError("后台正在停用或更新，请重新注册后再启动。") }
                        if !service.isEmpty {
                            guard try serviceSnapshot().services.contains(service) else { throw ControlError("网络服务不存在或已停用。") }
                        }
                        try connect(root: URL(fileURLWithPath: BuildSettings.projectRoot), profile: profile,
                            service: service, owner: self.owner, additionalCIDRs: additionalCIDRs)
                    case "stop": try stop()
                    case "prepareUpdate":
                        try stop()
                        serviceUpdating = true
                    case "logs":
                        let files = ["sslocal.log", "coredns.log", "watchdog.log"].map { Runtime.directory.appendingPathComponent($0).path }
                            .filter { fm.fileExists(atPath: $0) }
                        let text = files.isEmpty ? "暂无日志。" : try Command.run("/usr/bin/tail", ["-n", "100"] + files).output
                        return Data(text.utf8)
                    default: break
                    }
                    return try JSONEncoder().encode(serviceSnapshot())
                }
                reply(data, nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
}

func serviceSnapshot() throws -> ServiceSnapshot {
    var status: PublicStatus?
    if fm.fileExists(atPath: Runtime.state.path) {
        let state = try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: Runtime.state))
        status = PublicStatus(profile: state.profile, service: state.service, processes: state.processes,
            ready: state.phase == .ready, watchdog: state.watchdog, lastChecked: nil)
        if let data = try? Data(contentsOf: Runtime.summary), let published = try? JSONDecoder().decode(PublicStatus.self, from: data) {
            status = published
        }
    }
    let event = fm.fileExists(atPath: Runtime.event.path)
        ? try JSONDecoder().decode(RecoveryEvent.self, from: Data(contentsOf: Runtime.event)) : nil
    let output = try Command.run("/usr/sbin/networksetup", ["-listallnetworkservices"]).output
    let services = output.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    return ServiceSnapshot(status: status, recovery: event, services: services,
        legacy: fm.fileExists(atPath: Runtime.legacyToken))
}

final class ServiceListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == BuildSettings.ownerUID else { return false }
        let identity = ManagedProcess.identity(connection.processIdentifier)
        guard !identity.isEmpty else { return false }
        connection.setCodeSigningRequirement(ServiceIdentity.requirement(identifier: ServiceIdentity.appID))
        connection.exportedInterface = NSXPCInterface(with: ProxyServiceProtocol.self)
        connection.exportedObject = ServiceEndpoint(owner: ManagedProcess(pid: connection.processIdentifier, identity: identity))
        connection.resume()
        return true
    }
}

func runServiceDaemon() throws {
    signal(SIGTERM, SIG_IGN)
    let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "com.dfordsoft.climbover.shutdown"))
    termination.setEventHandler {
        for _ in 0..<10 {
            do {
                try locked {
                    serviceUpdating = true
                    try stop(reason: "后台服务正在停止")
                }
                exit(0)
            } catch is ControlBusy {
                Thread.sleep(forTimeInterval: 0.2)
            } catch {
                // The independent watchdog keeps retrying the retained recovery journal.
                recordRecovery("后台停止时恢复尚未完成：\(error.localizedDescription)", completed: false)
                exit(1)
            }
        }
        exit(1)
    }
    termination.resume()
    try locked {
        try ensureRuntimeDirectory()
        // A daemon restart never silently adopts a possibly incomplete old session.
        if fm.fileExists(atPath: Runtime.state.path) {
            do { try stop(reason: "后台服务重新启动"); recordRecovery("后台重新启动，旧会话已安全停止。", completed: true) }
            catch { recordRecovery("后台重新启动，旧会话恢复需重试：\(error.localizedDescription)", completed: false) }
        }
    }
    let recoveryTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.dfordsoft.climbover.recovery"))
    recoveryTimer.schedule(deadline: .now() + 2, repeating: 2)
    recoveryTimer.setEventHandler {
        do {
            try locked(waitForMonitor: false) {
                guard fm.fileExists(atPath: Runtime.state.path) else { return }
                let state = try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: Runtime.state))
                if state.watchdog?.alive != true {
                    try stop(reason: "后台监控已退出")
                    recordRecovery("后台监控已退出，已停止代理并恢复网络。", completed: true)
                }
            }
        } catch is ControlBusy { } catch { recordRecovery(error.localizedDescription, completed: false) }
    }
    recoveryTimer.resume()
    let delegate = ServiceListener()
    let listener = NSXPCListener(machServiceName: ServiceIdentity.name)
    listener.delegate = delegate
    listener.resume()
    withExtendedLifetime((delegate, listener, recoveryTimer, termination)) { RunLoop.current.run() }
}
