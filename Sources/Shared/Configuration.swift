import Foundation

enum RuntimeConfiguration {
    static func write(proxy: Data, directory: URL, blocklist: URL) throws {
        let config = directory.appendingPathComponent("config.json")
        try proxy.write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        try CoreDNSConfiguration.render(blocklist: blocklist)
            .write(to: directory.appendingPathComponent("Corefile"), atomically: true, encoding: .utf8)
        try PFConfiguration.render(tableFile: directory.appendingPathComponent("direct_cidr.txt"))
            .write(to: directory.appendingPathComponent("pf.conf"), atomically: true, encoding: .utf8)
    }
}

enum CoreDNSConfiguration {
    static func render(blocklist: URL) -> String {
        ConfigurationTemplates.coreDNS
            .replacingOccurrences(of: "{{DIRECT_DOMAINS}}", with: words(ConfigurationTemplates.directDomains))
            .replacingOccurrences(of: "{{BOGUS_RESPONSES}}", with: words(ConfigurationTemplates.bogusResponses))
            .replacingOccurrences(of: "{{APPLE_DOMAINS}}", with: words(ConfigurationTemplates.appleDomains))
            .replacingOccurrences(of: "{{BILI_DOMAINS}}", with: words(ConfigurationTemplates.biliDomains))
            .replacingOccurrences(of: "{{BLOCKLIST_FILE}}", with: configurationPath(blocklist))
    }

    private static func words(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

enum PFConfiguration {
    static func render(tableFile: URL) -> String {
        // The template includes the final newline required by macOS pfctl.
        ConfigurationTemplates.packetFilter.replacingOccurrences(of: "{{DIRECT_CIDR_FILE}}", with: configurationPath(tableFile))
    }
}

private func configurationPath(_ url: URL) -> String {
    "\"" + url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
