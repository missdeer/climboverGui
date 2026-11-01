import Foundation

func testDNSVariables() throws {
    let legacy = try JSONSerialization.data(withJSONObject: ["sslocal": ConfigurationTemplates.sslocal, "coreDNS": ConfigurationTemplates.coreDNS])
    let migrated = try EditableTemplates.decode(String(decoding: legacy, as: UTF8.self))
    require(migrated == EditableTemplates(), "Existing preferences must keep bundled defaults")
    var draft = migrated
    let edits: [(ConfigurationTemplateSection, String)] = [
        (.directDomains, "https://example.com/direct.txt"), (.bogusResponses, "http://example.com/ips.txt"),
        (.appleDomains, "https://example.com/apple.txt"), (.blocklistFile, "https://example.com/blocklist.txt")]
    for (section, text) in edits { section.update(text, in: &draft) }
    let decoded = try EditableTemplates.decode(draft.encoded())
    require(decoded == draft, "URL settings must survive preferences and XPC serialization")
    for (section, text) in edits { require(section.text(in: decoded) == text, "Editors must preserve their own URL") }
    for (section, _) in edits { section.update(section.defaultText, in: &draft) }
    require(draft == migrated, "Restoring defaults must clear URLs without changing templates")
    try DNSVariables(directDomains: ConfigurationTemplates.directDomains, bogusResponses: ConfigurationTemplates.bogusResponses,
        appleDomains: ConfigurationTemplates.appleDomains).validate()
    for invalid in ["example.com #comment", "example.com\n}", "example.com\0", "{{APPLE_DOMAINS}}"] {
        rejects("Unsafe domain-list token") { try DNSVariables(directDomains: invalid).validate() }
    }
    for invalid in ["999.1.1.1", "example.com", "192.0.2.1\0bad"] {
        rejects("Invalid bogus IP") { try DNSVariables(bogusResponses: invalid).validate() }
    }
    for invalid in ["file:///tmp/list.txt", "ftp://example.com/list", "https://", "relative.txt", "https://example.com/\n"] {
        rejects("Invalid variable URL") { _ = try RemoteTemplateVariables.sourceURL(invalid) }
    }
    let oldTemplate = ConfigurationTemplates.coreDNS.replacingOccurrences(of: "appleroute", with: "biliroute {{BILI_DOMAINS}}\n        appleroute")
    let oldPayload = try JSONSerialization.data(withJSONObject: ["sslocal": ConfigurationTemplates.sslocal,
        "coreDNS": oldTemplate, "dnsVariables": ["biliDomains": "bili.example", "appleDomains": "apple.example"]])
    let withoutBili = try EditableTemplates.decode(String(decoding: oldPayload, as: UTF8.self))
    require(!withoutBili.coreDNS.contains("biliroute") && !withoutBili.coreDNS.contains("BILI_DOMAINS"), "Old saved Bilibili routes must be removed automatically")
    require(withoutBili.dnsVariables?.appleDomains == "apple.example", "Migration must preserve other saved values")
    let rendered = CoreDNSConfiguration.render(blocklist: URL(fileURLWithPath: "/tmp/list with spaces.txt"), template: oldTemplate,
        variables: DNSVariables(directDomains: "direct.example\nsecond.example", bogusResponses: "192.0.2.1\n2001:db8::1", appleDomains: "apple.example"))
    require(rendered.contains("except direct.example second.example") && rendered.contains("bogus 192.0.2.1 2001:db8::1") && rendered.contains("appleroute apple.example"), "Downloaded values must fill their own placeholders")
    require(!rendered.contains("biliroute") && !rendered.contains("{{"), "Rendering must omit the removed route")
    require(rendered.contains("blocklist \"/tmp/list with spaces.txt\""), "Blocklist paths must be quoted")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let blocklist = directory.appendingPathComponent("blocklist.txt")
    try RuntimeConfiguration.write(proxy: Data("{}".utf8), directory: directory, blocklist: blocklist, corefile: rendered, blocklistContent: "old.example\n")
    let snapshot = try String(contentsOf: blocklist, encoding: .utf8)
    try RuntimeConfiguration.write(proxy: Data("{}".utf8), directory: directory, blocklist: blocklist, blocklistContent: "new.example\n")
    try RuntimeConfiguration.write(proxy: Data("{}".utf8), directory: directory, blocklist: blocklist, corefile: rendered, blocklistContent: snapshot)
    let restored = try String(contentsOf: blocklist, encoding: .utf8)
    require(restored == "old.example\n", "Rollback must restore the previous downloaded blocklist content")
    try RuntimeConfiguration.write(proxy: Data("{}".utf8), directory: directory, blocklist: blocklist)
    require(!FileManager.default.fileExists(atPath: blocklist.path), "Using the default file must remove a stale runtime download")
    print("PASS: URL editors, migration, rendering, defaults, validation and blocklist snapshots")
}
