import Foundation

func testConfigurationTemplates() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source: [String: Any] = ["protocol": "redir", "server": "192.0.2.1", "server_port": 443,
        "method": "aes-128-gcm", "password": "quoted\"\\secret", "plugin_opts": "obfs=http"]
    let proxy = try JSONSerialization.data(withJSONObject: Profile.normalize(source))
    let blocklist = directory.appendingPathComponent("project with spaces/domains.txt")
    try RuntimeConfiguration.write(proxy: proxy, directory: directory, blocklist: blocklist)
    let config = directory.appendingPathComponent("config.json")
    let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    require(decoded["password"] as? String == source["password"] as? String, "Template must preserve quoted node credentials")
    require(decoded["plugin_opts"] as? String == "obfs=http", "Template must preserve plugin options")
    let attributes = try FileManager.default.attributesOfItem(atPath: config.path)
    require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Proxy credentials must be owner-only")
    let corefile = try String(contentsOf: directory.appendingPathComponent("Corefile"), encoding: .utf8)
    require(corefile.contains("blocklist \"\(blocklist.path)\""), "DNS data paths with spaces must be quoted and absolute")
    require(corefile.contains("bind 127.0.0.1") && corefile.contains("except ") && corefile.contains("taobao.com"), "DNS must preserve loopback binding and split routing")
    require(!corefile.contains("{{"), "All CoreDNS template parameters must be filled")
    // Stale/tampered runtime files must never become the input to a new start.
    for name in ["config.json", "Corefile", "pf.conf"] {
        try "stale".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    var next = source
    next["server"] = "192.0.2.2"
    let nextProxy = try JSONSerialization.data(withJSONObject: Profile.normalize(next))
    try RuntimeConfiguration.write(proxy: nextProxy, directory: directory, blocklist: blocklist)
    let rewritten = try Data(contentsOf: config)
    let rewrittenDNS = try String(contentsOf: directory.appendingPathComponent("Corefile"), encoding: .utf8)
    let rules = try String(contentsOf: directory.appendingPathComponent("pf.conf"), encoding: .utf8)
    require(rewritten == nextProxy && rewrittenDNS == corefile && rules.hasSuffix("\n") && !rules.contains("{{"), "Each start must regenerate all three configurations from templates")
    let quotedPath = CoreDNSConfiguration.render(blocklist: directory.appendingPathComponent("a\"b\\c.txt"))
    require(quotedPath.contains("a\\\"b\\\\c.txt"), "Configuration paths must escape quotes and backslashes")
    print("PASS: embedded templates, DNS split routing, node parameters, private permissions and fresh configuration on every start")
}
