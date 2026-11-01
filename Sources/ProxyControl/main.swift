import Foundation
import Darwin

let fm = FileManager.default

func save(_ state: SessionState, ready: Bool = false) throws {
    try JSONEncoder().encode(state).write(to: Runtime.state, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Runtime.state.path)
    try publishStatus(state, ready: ready)
}

func publishStatus(_ state: SessionState, ready: Bool) throws {
    let status = PublicStatus(profile: state.profile, service: state.service, processes: state.processes,
        ready: ready, watchdog: state.watchdog, lastChecked: Date())
    try JSONEncoder().encode(status).write(to: Runtime.summary, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Runtime.summary.path)
}

func dns(_ service: String) throws -> [String] {
    let output = try Command.run("/usr/sbin/networksetup", ["-getdnsservers", service]).output
    let lines = output.split(separator: "\n").map(String.init)
    if output.contains("There aren't any DNS Servers set") { return [] }
    guard !lines.isEmpty, lines.allSatisfy(isIPAddress) else {
        throw ControlError("无法读取网络服务“\(service)”的 DNS 设置。")
    }
    return lines
}

func defaultService() throws -> String {
    let route = try Command.run("/sbin/route", ["-n", "get", "default"]).output
    guard let interface = route.split(separator: "\n").first(where: { $0.contains("interface:") })?
        .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
        throw ControlError("未找到默认网络接口。")
    }
    let order = try Command.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]).output
    var service = ""
    for line in order.split(separator: "\n").map(String.init) {
        if line.hasPrefix("("), let end = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware") {
            service = String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        if line.contains("Device: \(interface))"), !service.isEmpty { return service }
    }
    throw ControlError("无法匹配默认网络服务。请在面板中手动选择。")
}

func stop(reason: String? = nil) throws {
    guard fm.fileExists(atPath: Runtime.state.path) else {
        // Idempotent Stop also removes stale rules from our reserved anchor after a lost journal.
        try PFVerification.clear(flush: PacketFilter.flush, verify: PacketFilter.verifyEmpty)
        return
    }
    var state = try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: Runtime.state))
    if let reason { state.recoveryReason = reason }
    let actions = RecoveryActions(readDNS: dns, writeDNS: { service, servers in
        _ = try Command.run("/usr/sbin/networksetup", ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers))
    }, flushPF: PacketFilter.flush, verifyPF: PacketFilter.verifyEmpty, releasePF: PacketFilter.release,
       terminate: terminateManagedProcess, checkpoint: { try save($0) })
    let failures = SessionRecovery.run(state: &state, actions: actions)
    guard failures.isEmpty else {
        throw ControlError("恢复尚未完成，将由监控进程重试：\n" + failures.joined(separator: "\n"))
    }
    try PacketFilter.verifyEmpty()
    let config = Runtime.directory.appendingPathComponent("config.json")
    if fm.fileExists(atPath: config.path) { try fm.removeItem(at: config) }
    try? fm.removeItem(at: Runtime.summary)
    try fm.removeItem(at: Runtime.state)
}

func resolve(_ hostname: String) throws -> String {
    if isIPAddress(hostname) { return hostname }
    guard !hostname.isEmpty, !hostname.hasPrefix("-"), hostname.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else {
        throw ControlError("服务器域名格式无效。")
    }
    let result = try Command.run("/usr/bin/dig", ["@119.29.29.29", hostname, "A", "+short", "+time=3", "+tries=1"])
    guard let ip = result.output.split(separator: "\n").map(String.init).first(where: isIPAddress) else {
        throw ControlError("无法解析服务器域名 \(hostname)。")
    }
    return ip
}

func prepareConfig(_ input: [String: Any], root: URL) throws -> (Data, [String]) {
    var addresses: [String] = []
    func server(_ input: [String: Any]) throws -> [String: Any] {
        var output = input
        if let hostname = output["server"] as? String {
            let address = try resolve(hostname)
            output["server"] = address
            addresses.append(address)
        }
        if let proxy = output["outbound_proxy"] as? String {
            guard var url = URLComponents(string: proxy), let host = url.host else {
                throw ControlError("无法解析配置中的 outbound_proxy。")
            }
            let address = try resolve(host)
            url.host = address
            guard let value = url.string else { throw ControlError("无法生成链式代理配置。") }
            output["outbound_proxy"] = value
            addresses.append(address)
        }
        if let plugin = output["plugin"] as? String, !plugin.isEmpty {
            let path = try BundledTools.plugin(plugin, root: root, helper: ExecutableLocation.current()).path
            guard fm.isExecutableFile(atPath: path) else { throw ControlError("找不到代理插件：\(plugin)") }
            output["plugin"] = path
        }
        if let acl = output["acl"] as? String, !acl.hasPrefix("/") {
            output["acl"] = root.appendingPathComponent(acl).path
        }
        return output
    }
    var output = try server(input)
    if let servers = input["servers"] as? [[String: Any]] {
        output["servers"] = try servers.map(server)
    }
    return (try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), addresses)
}

func spawn(_ executable: URL, _ arguments: [String], directory: URL, log: String, sessionID: String? = nil) throws -> ManagedProcess {
    let logURL = Runtime.directory.appendingPathComponent(log)
    let helper = try ExecutableLocation.current()
    let launchArguments = sessionID.map { ["child", $0, executable.path] + arguments } ?? arguments
    let pid = try DetachedProcess.launch(executable: sessionID == nil ? executable : helper,
        arguments: launchArguments, directory: directory, log: logURL)
    // Journal the child immediately; readiness is checked after all PIDs are saved.
    var exitStatus: Int32 = 0
    guard waitpid(pid, &exitStatus, WNOHANG) == 0 else {
        throw ControlError("\(executable.lastPathComponent) 启动失败，请查看日志。")
    }
    let identity = ManagedProcess.identity(pid)
    guard !identity.isEmpty else {
        kill(pid, SIGTERM)
        throw ControlError("无法记录 \(executable.lastPathComponent) 进程身份。")
    }
    return ManagedProcess(pid: pid, identity: identity)
}

func waitForListeners(_ state: SessionState) throws {
    for _ in 0..<40 {
        guard state.processes.allSatisfy(\.alive) else { throw ControlError("代理进程已退出，请查看日志。") }
        let tcp = try Command.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(state.processes[0].pid), "-iTCP:59097", "-sTCP:LISTEN"], checked: false)
        let udp = try Command.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(state.processes[1].pid), "-iUDP:53"], checked: false)
        if tcp.status == 0 && udp.status == 0 { return }
        usleep(150_000)
    }
    throw ControlError("代理或 DNS 未在预期端口就绪，请查看日志。")
}

func start(root: URL, profile: String, service: String, owner: ManagedProcess?, prepared: PreparedServer, additionalCIDRs: [String]) throws {
    guard !fm.fileExists(atPath: Runtime.legacyToken) else {
        throw ControlError("命令行脚本代理正在运行。请先在终端执行 sudo ./stop.sh，再使用 GUI。")
    }
    let data = prepared.data
    let endpoints = prepared.endpoints
    let chosenService = try service.isEmpty ? defaultService() : service
    let originalDNS = try dns(chosenService)
    let helper = try ExecutableLocation.current()
    let sslocal = BundledTools.executable("sslocal", helper: helper)
    let coredns = BundledTools.executable("coredns", helper: helper)
    for file in [sslocal, coredns] {
        guard fm.isExecutableFile(atPath: file.path) else { throw ControlError("找不到可执行文件：\(file.path)") }
    }
    let filter = try Command.run("/sbin/pfctl", ["-sr"]).output
    let nat = try Command.run("/sbin/pfctl", ["-sn"]).output
    guard filter.contains("anchor \"com.apple/*\""), nat.contains("rdr-anchor \"com.apple/*\"") else {
        throw ControlError("PF 基础规则缺少 com.apple 通配 anchor。请先检查 /etc/pf.conf 并加载标准规则。")
    }
    for port in ["-iTCP:59097", "-iTCP:\(ProbeConfiguration.port)", "-iUDP:53", "-iTCP:53"] {
        let selection = port.contains("TCP") ? ["-nP", port, "-sTCP:LISTEN"] : ["-nP", port]
        let busy = try Command.run("/usr/sbin/lsof", selection, checked: false)
        guard busy.status != 0 else { throw ControlError("端口已被其他程序占用：\(port)。请先停止已有代理或 DNS 服务。") }
    }
    let base = try ["direct_cidr.txt", "lan_cidr.txt"].map {
        try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
    }
    let cidrs = try DirectCIDRs.render(base: base, endpoints: endpoints, additional: additionalCIDRs)
    try cidrs.write(to: Runtime.directory.appendingPathComponent("direct_cidr.txt"), atomically: true, encoding: .utf8)
    let configURL = Runtime.directory.appendingPathComponent("config.json")
    try RuntimeConfiguration.write(proxy: data, directory: Runtime.directory,
        blocklist: root.appendingPathComponent("coredns/domains.txt"), corefile: prepared.corefile, blocklistContent: prepared.blocklistContent)
    try "[proxy_all]\n".write(to: Runtime.directory.appendingPathComponent("probe.acl"), atomically: true, encoding: .utf8)
    let corefileURL = Runtime.directory.appendingPathComponent("Corefile")
    let rulesURL = Runtime.directory.appendingPathComponent("pf.conf")
    _ = try Command.run("/sbin/pfctl", ["-n", "-a", Runtime.anchor, "-f", rulesURL.path])
    var state = SessionState(profile: profile, service: chosenService, originalDNS: originalDNS)
    state.additionalCIDRs = additionalCIDRs
    state.sessionID = UUID().uuidString
    state.owner = owner
    state.phase = .starting
    try save(state)
    do {
        state.watchdog = try spawn(helper, ["watch", state.sessionID!], directory: Runtime.directory, log: "watchdog.log")
        try save(state)
        // Keep cwd alongside the bundled obfs-local, independent of the original build-machine paths.
        state.processes.append(try spawn(sslocal, ["-c", configURL.path], directory: sslocal.deletingLastPathComponent(), log: "sslocal.log", sessionID: state.sessionID))
        state.companions = try childProcesses(of: state.processes[0].pid)
        try save(state)
        state.processes.append(try spawn(coredns, ["-conf", corefileURL.path], directory: Runtime.directory, log: "coredns.log", sessionID: state.sessionID))
        try save(state)
        try waitForListeners(state)
        state.companions = try childProcesses(of: state.processes[0].pid)
        try save(state)
        _ = try Command.run("/sbin/pfctl", ["-a", Runtime.anchor, "-f", rulesURL.path])
        let enabled = try Command.run("/sbin/pfctl", ["-E"]).output
        guard let tokenLine = enabled.split(separator: "\n").first(where: { $0.contains("Token :") }),
              let token = tokenLine.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !token.isEmpty else {
            throw ControlError("无法获取 PF 引用令牌。")
        }
        state.pfToken = token
        try save(state)
        state.dnsChanged = true
        try save(state)
        _ = try Command.run("/usr/sbin/networksetup", ["-setdnsservers", chosenService, "127.0.0.1"])
        try verifyConnectivity(state)
        try PacketFilter.verifyActive(token: token)
        state.phase = .ready
        try save(state, ready: true)
        try? fm.removeItem(at: Runtime.event)
    } catch {
        do { try stop() } catch let cleanupError {
            throw ControlError("\(error.localizedDescription)\n恢复尚未完成：\(cleanupError.localizedDescription)\n请再次点击停止。")
        }
        throw error
    }
}

func locked<T>(waitForMonitor: Bool = true, _ body: () throws -> T) throws -> T {
    let fd = open("/var/run/climbover-gui.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw ControlError("无法创建操作锁。") }
    defer { close(fd) }
    var acquired = flock(fd, LOCK_EX | LOCK_NB) == 0
    if !acquired && waitForMonitor {
        // Brief watchdog readback must not make a normal Stop fail spuriously.
        for _ in 0..<60 {
            usleep(50_000)
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
        }
    }
    guard acquired else { throw ControlBusy() }
    defer { flock(fd, LOCK_UN) }
    return try body()
}

func ensureRuntimeDirectory() throws {
    if fm.fileExists(atPath: Runtime.directory.path) {
        let attrs = try fm.attributesOfItem(atPath: Runtime.directory.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0 else {
            throw ControlError("运行状态目录所有权异常。")
        }
    } else {
        try fm.createDirectory(at: Runtime.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    }
}

func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 3, args[0] == "check" {
        let root = URL(fileURLWithPath: args[1]).resolvingSymlinksInPath()
        _ = try Profile.read(Profile.url(root: root, relative: args[2]))
        print("配置有效；运行时使用 TCP redir 127.0.0.1:59097。")
        return
    }
    guard geteuid() == 0 else { throw ControlError("启停需要管理员授权。") }
    umask(0o077)
    if args == ["daemon"] { try runServiceDaemon(); return }
    if args.count >= 3, args[0] == "child", UUID(uuidString: args[1]) != nil {
        try runChild(sessionID: args[1], executable: args[2], arguments: Array(args.dropFirst(3)))
        return
    }
    if args.count == 2, args[0] == "watch", UUID(uuidString: args[1]) != nil {
        watch(sessionID: args[1])
        return
    }
    guard args == ["stop"] || ([4, 5].contains(args.count) && args[0] == "start") else {
        throw ControlError("用法：ProxyControl start 项目目录 配置相对路径 网络服务名 [GUI进程ID]；ProxyControl stop")
    }
    try locked {
        try ensureRuntimeDirectory()
        if args[0] == "stop" { try stop(); print("代理已停止，网络设置已恢复。") }
        else {
            var owner: ManagedProcess?
            if args.count == 5 {
                guard let pid = Int32(args[4]), pid > 1 else { throw ControlError("无效的 GUI 进程 ID。") }
                let identity = ManagedProcess.identity(pid)
                guard !identity.isEmpty else { throw ControlError("GUI 已退出，取消启动。") }
                owner = ManagedProcess(pid: pid, identity: identity)
            }
            try connect(root: URL(fileURLWithPath: args[1]).resolvingSymlinksInPath(), profile: args[2], service: args[3], owner: owner)
            print("代理已启动。")
        }
    }
}

do { try main() } catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
