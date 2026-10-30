import Foundation

struct PreparedServer {
    let data: Data
    let endpoints: [String]
}

func prepareServer(root: URL, profile: String, snapshot: Data? = nil) throws -> PreparedServer {
    let config: [String: Any]
    if let snapshot {
        guard let object = try JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
            throw ControlError("旧节点运行配置副本无效，未执行切换。")
        }
        config = object
    } else { config = try Profile.read(Profile.url(root: root, relative: profile)) }
    let (data, endpoints) = try prepareConfig(config, root: root)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ControlError("无法生成运行配置。")
    }
    let runtime = ProbeConfiguration.addingListener(to: object, acl: Runtime.directory.appendingPathComponent("probe.acl"))
    return PreparedServer(data: try JSONSerialization.data(withJSONObject: runtime, options: [.prettyPrinted, .sortedKeys]), endpoints: endpoints)
}

func verifyConnectivity(_ state: SessionState) throws {
    try ConnectionCheck.verify(resolve: {
        let query = try Command.run("/usr/bin/dig", ["@127.0.0.1", "example.com", "A", "+short", "+time=5", "+tries=1"])
        return query.output.split(separator: "\n").map(String.init).contains(where: isIPAddress)
    }, https: { url in
    // SOCKS hostname resolution happens on the remote server. Per-listener ACL forces proxy use.
        guard state.owner?.alive != false else { throw ControlError("GUI 已退出，取消连接验证。") }
        let result = try Command.run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--noproxy", "",
            "--socks5-hostname", "127.0.0.1:\(ProbeConfiguration.port)", "--connect-timeout", "4", "--max-time", "8", url,
            "-o", "/dev/null"], checked: false)
        guard result.status == 0 else { throw ControlError(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return true
    })
}

func connect(root: URL, profile: String, service: String, owner: ManagedProcess?, additionalCIDRs: String = "") throws {
    let additional = try DirectCIDRs.parse(additionalCIDRs)
    let previous = fm.fileExists(atPath: Runtime.state.path)
        ? try JSONDecoder().decode(SessionState.self, from: Data(contentsOf: Runtime.state)) : nil
    let canRestore = previous?.phase == .ready
    // Snapshot the configuration actually in use, including resolved chain endpoints and plugin paths.
    let snapshot = canRestore ? try Data(contentsOf: Runtime.directory.appendingPathComponent("config.json")) : nil
    let sessionOwner = owner ?? previous?.owner
    var candidate: PreparedServer?
    var fallback: PreparedServer?
    let actions = SwitchActions(validate: {
        candidate = try prepareServer(root: root, profile: profile)
        if let previous, let snapshot { fallback = try prepareServer(root: root, profile: previous.profile, snapshot: snapshot) }
    }, stop: { try stop() }, connect: {
        guard let candidate else { throw ControlError("新节点尚未准备完成。") }
        try start(root: root, profile: profile, service: service.isEmpty ? (previous?.service ?? "") : service,
            owner: sessionOwner, prepared: candidate, additionalCIDRs: additional)
    }, restore: canRestore ? {
        guard let previous, let fallback else { throw ControlError("旧节点运行配置未保存。") }
        guard sessionOwner?.alive != false else { throw ControlError("GUI 已退出，取消回退。") }
        try start(root: root, profile: previous.profile, service: previous.service, owner: sessionOwner, prepared: fallback, additionalCIDRs: previous.additionalCIDRs ?? [])
    } : nil)
    try ServerSwitch.run(previous: canRestore ? previous?.profile : nil, actions: actions)
}
