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

func testEditableTemplates() throws {
    let defaults = EditableTemplates()
    let decodedDefaults = try EditableTemplates.decode("")
    require(decodedDefaults == defaults, "An empty XPC payload must select bundled defaults")
    var custom = defaults
    custom.sslocal = """
    {"protocol":"redir","local_address":"127.0.0.1","local_port":59097,"mode":"tcp_only","tcp_keep_alive":45}
    """
    custom.coreDNS = ". {\n bind 127.0.0.1\n forward . 1.1.1.1\n blocklist {{BLOCKLIST_FILE}}\n}\n"
    let payload = try custom.encoded()
    let decodedCustom = try EditableTemplates.decode(payload)
    require(decodedCustom == custom, "Both templates must survive preference/XPC encoding")
    try ServiceRequest.validate("start", profile: "node.conf", service: "", templatesJSON: payload)
    let source: [String: Any] = ["protocol": "redir", "server": "192.0.2.1", "server_port": 443,
        "password": "secret", "method": "aes-128-gcm"]
    let old = try Profile.normalize(source, template: custom.sslocal)
    require(old["tcp_keep_alive"] as? Int == 45 && old["password"] as? String == "secret", "Custom listener values must merge without replacing node credentials")
    var modern = source
    modern["locals"] = [["protocol": "redir", "local_port": 1234]]
    let normalized = try Profile.normalize(modern, template: custom.sslocal)
    let local = (normalized["locals"] as! [[String: Any]])[0]
    require(local["tcp_keep_alive"] as? Int == 45 && local["local_port"] as? Int == 59097, "Modern listeners must use the same custom template")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocklist = directory.appendingPathComponent("list with spaces.txt")
    let rendered = CoreDNSConfiguration.render(blocklist: blocklist, template: custom.coreDNS)
    require(rendered.contains("1.1.1.1") && rendered.contains("\"\(blocklist.path)\"") && !rendered.contains("{{"), "Custom DNS upstreams and path substitution must reach the generated Corefile")
    let proxy = try JSONSerialization.data(withJSONObject: old)
    try RuntimeConfiguration.write(proxy: proxy, directory: directory, blocklist: blocklist, corefile: rendered)
    let savedDNS = try String(contentsOf: directory.appendingPathComponent("Corefile"), encoding: .utf8)
    try RuntimeConfiguration.write(proxy: proxy, directory: directory, blocklist: blocklist)
    try RuntimeConfiguration.write(proxy: proxy, directory: directory, blocklist: blocklist, corefile: savedDNS)
    let restoredDNS = try String(contentsOf: directory.appendingPathComponent("Corefile"), encoding: .utf8)
    require(restoredDNS == rendered, "Rollback must restore the actual previous Corefile rather than current defaults")
    for invalid in ["[]", "{}", "not json", custom.sslocal.replacingOccurrences(of: "59097", with: "59098"),
                    custom.sslocal.replacingOccurrences(of: "127.0.0.1", with: "0.0.0.0")] {
        rejects("Invalid sslocal template") { try EditableTemplates(sslocal: invalid).validate() }
    }
    for invalid in ["", " \n", "bad\0", "{{UNKNOWN}}", "{{BLOCKLIST_FILE}", String(repeating: "x", count: EditableTemplates.maximumBytes + 1)] {
        rejects("Invalid CoreDNS template") { try EditableTemplates(coreDNS: invalid).validate() }
    }
    rejects("Unbounded XPC templates") { try ServiceRequest.validate("start", profile: "node.conf", service: "", templatesJSON: String(repeating: "x", count: EditableTemplates.maximumBytes + 1)) }
    rejects("Malformed template payload") { _ = try EditableTemplates.decode("{}") }
    print("PASS: editable templates, XPC validation, listener merge, DNS rendering and rollback Corefile")
}
