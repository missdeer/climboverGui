import Foundation

func testDirectDomains() throws {
    let domains = try DirectDomains.parse(" Example.COM.\r\n\nexample.com\nsub.example.net ")
    require(domains == ["example.com", "sub.example.net"], "Domains must normalize case, trailing dots and duplicates")
    let cleared = try DirectDomains.parse(" \n")
    require(cleared.isEmpty, "Empty settings must clear extra domains")
    for value in [".", "a..com", "-a.com", "a-.com", "https://example.com", "a.com/path", "*.example.com",
                  "a.com b.com", "a.com\0", "a.com {", "192.0.2.1", "中文.com", String(repeating: "a", count: 64) + ".com"] {
        rejects("Invalid extra domain: \(value)") { _ = try DirectDomains.parse(value) }
    }
    rejects("Oversized domain settings") { _ = try DirectDomains.parse(String(repeating: "\n", count: DirectDomains.maximumBytes + 1)) }
    var templates = EditableTemplates()
    templates.additionalDirectDomains = domains.joined(separator: "\n")
    let payload = try templates.encoded()
    let decoded = try EditableTemplates.decode(payload)
    require(decoded.additionalDirectDomains == templates.additionalDirectDomains, "Extra domains must cross the authenticated XPC payload")
    templates.additionalDirectDomains = "a.com\n}"
    rejects("Privileged request validates domains") {
        let data = try JSONEncoder().encode(templates)
        try ServiceRequest.validate("start", profile: "node.conf", service: "", templatesJSON: String(decoding: data, as: UTF8.self))
    }
    let legacy = ConfigurationTemplates.coreDNS.replacingOccurrences(of: CoreDNSConfiguration.additionalDomainsPlaceholder, with: "")
    let blocklist = URL(fileURLWithPath: "/tmp/blocklist.txt")
    let corefile = CoreDNSConfiguration.render(blocklist: blocklist, template: legacy, additionalDomains: domains)
    require(corefile.contains("direct_cidr:\(Runtime.anchor) example.com sub.example.net") && !corefile.contains("{{"), "Saved Corefiles must gain the ipset mapping")
    let empty = CoreDNSConfiguration.render(blocklist: blocklist)
    require(!empty.contains("direct_cidr"), "Empty settings must not produce a catch-all ipset directive")
    rejects("Custom template must support extra domains") {
        try EditableTemplates(coreDNS: ". { forward . 1.1.1.1 }", additionalDirectDomains: "example.com").validate()
    }
    print("PASS: extra domains, XPC validation, legacy Corefiles, empty lists and native PF anchor syntax")
}
