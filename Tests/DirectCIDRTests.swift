import Foundation

func testDirectCIDRs() throws {
    let parsed = try DirectCIDRs.parse(" 192.168.1.0/24 \r\n\n10.0.0.0/8\n192.168.1.0/24\n0.0.0.0/0\n192.0.2.1/32")
    require(parsed == ["192.168.1.0/24", "10.0.0.0/8", "0.0.0.0/0", "192.0.2.1/32"], "Trim whitespace, handle CRLF, remove duplicates and accept boundary prefixes")
    let empty = try DirectCIDRs.parse(" \n\t")
    require(empty.isEmpty, "Empty settings must clear additional CIDRs")
    for value in ["192.0.2.1", "300.0.0.0/8", "192.0.2.0/33", "192.0.2.0/-1", "192.0.2.0/", "::/0", "example.com/24", "192.0.2.0/24 pass out all", "192.0.2.0/24\0"] {
        rejects("Invalid extra CIDR: \(value)") { _ = try DirectCIDRs.parse(value) }
    }
    rejects("Oversized CIDR settings") { _ = try DirectCIDRs.parse(String(repeating: "\n", count: DirectCIDRs.maximumBytes + 1)) }
    rejects("Privileged request validates CIDRs") {
        try ServiceRequest.validate("start", profile: "node.conf", service: "", additionalCIDRs: "pass out all")
    }
    let table = try DirectCIDRs.render(base: ["10.0.0.0/8\n", "172.16.0.0/12\n"],
        endpoints: ["203.0.113.5", "2001:db8::1"], additional: parsed)
    for value in ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "203.0.113.5/32", "192.168.1.0/24"] {
        require(table.components(separatedBy: .newlines).contains(value), "Merged table must retain \(value)")
    }
    require(!table.contains("2001:db8"), "IPv4 PF rules must exclude IPv6 endpoints")
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tableFile = directory.appendingPathComponent("direct_cidr.txt")
    try table.write(to: tableFile, atomically: true, encoding: .utf8)
    let rulesFile = directory.appendingPathComponent("pf.conf")
    try PFConfiguration.render(tableFile: tableFile).write(to: rulesFile, atomically: true, encoding: .utf8)
    _ = try Command.run("/sbin/pfctl", ["-n", "-a", "com.apple/climbovergui-test", "-f", rulesFile.path])
    var state = SessionState(profile: "node.conf", service: "Wi-Fi", originalDNS: [])
    let legacy = try JSONEncoder().encode(state)
    let legacyState = try JSONDecoder().decode(SessionState.self, from: legacy)
    require(legacyState.additionalCIDRs == nil, "Old session journals must remain readable")
    state.additionalCIDRs = parsed
    let restored = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
    require(restored.additionalCIDRs == parsed, "Rollback journal must preserve the previous session's extra CIDRs")
    print("PASS: additional CIDR validation, merged PF table, native parser and rollback journal")
}
