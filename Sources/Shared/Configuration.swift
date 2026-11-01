import Foundation

enum RuntimeConfiguration {
    static func write(proxy: Data, directory: URL, blocklist: URL, corefile: String? = nil, blocklistContent: String? = nil) throws {
        let cachedBlocklist = directory.appendingPathComponent("blocklist.txt")
        if let blocklistContent {
            try blocklistContent.write(to: cachedBlocklist, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: cachedBlocklist.path) {
            try FileManager.default.removeItem(at: cachedBlocklist)
        }
        let config = directory.appendingPathComponent("config.json")
        try proxy.write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        try (corefile ?? CoreDNSConfiguration.render(blocklist: blocklist))
            .write(to: directory.appendingPathComponent("Corefile"), atomically: true, encoding: .utf8)
        try PFConfiguration.render(tableFile: directory.appendingPathComponent("direct_cidr.txt"))
            .write(to: directory.appendingPathComponent("pf.conf"), atomically: true, encoding: .utf8)
    }
}

enum CoreDNSConfiguration {
    static func render(blocklist: URL, template: String = ConfigurationTemplates.coreDNS, variables: DNSVariables = DNSVariables()) -> String {
        removingBilibiliRoute(from: template)
            .replacingOccurrences(of: "{{DIRECT_DOMAINS}}", with: words(variables.directDomains ?? ConfigurationTemplates.directDomains))
            .replacingOccurrences(of: "{{BOGUS_RESPONSES}}", with: words(variables.bogusResponses ?? ConfigurationTemplates.bogusResponses))
            .replacingOccurrences(of: "{{APPLE_DOMAINS}}", with: words(variables.appleDomains ?? ConfigurationTemplates.appleDomains))
            .replacingOccurrences(of: "{{BLOCKLIST_FILE}}", with: configurationPath(blocklist))
    }

    // Migrate the old template and any saved literal biliroute list without changing other routes.
    static func removingBilibiliRoute(from template: String) -> String {
        template.components(separatedBy: "\n").filter {
            $0.split(whereSeparator: { $0.isWhitespace }).first != "biliroute"
        }.joined(separator: "\n")
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

// User overrides travel through the authenticated XPC request; the root service never reads user preferences.
struct EditableTemplates: Codable, Equatable {
    var sslocal = ConfigurationTemplates.sslocal
    var coreDNS = ConfigurationTemplates.coreDNS
    var dnsVariables: DNSVariables? = nil
    var variableURLs: [String: String]? = nil
    static let preferencesKey = "configurationTemplates"
    static let maximumBytes = 32 * 1024 * 1024

    static func decode(_ text: String) throws -> EditableTemplates {
        if text.isEmpty { return EditableTemplates() }
        guard text.utf8.count <= maximumBytes else { throw ControlError("配置模板总大小不能超过 32 MB。") }
        var templates = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        templates.coreDNS = CoreDNSConfiguration.removingBilibiliRoute(from: templates.coreDNS)
        try templates.validate()
        return templates
    }

    func encoded() throws -> String {
        try validate()
        let text = String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        guard text.utf8.count <= Self.maximumBytes else { throw ControlError("配置模板总大小不能超过 32 MB。") }
        return text
    }

    func validate() throws {
        guard sslocal.utf8.count + coreDNS.utf8.count + (dnsVariables?.byteCount ?? 0) <= Self.maximumBytes,
              !sslocal.contains("\0"), !coreDNS.contains("\0"),
              !coreDNS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError("模板不能为空、包含 NUL 字符或超过 32 MB。")
        }
        try RemoteTemplateVariables.validateURLs(variableURLs ?? [:])
        try dnsVariables?.validate()
        _ = try listener()
        let placeholders = ["{{DIRECT_DOMAINS}}", "{{BOGUS_RESPONSES}}", "{{APPLE_DOMAINS}}", "{{BLOCKLIST_FILE}}"]
        let remainder = placeholders.reduce(coreDNS) { $0.replacingOccurrences(of: $1, with: "") }
        guard !remainder.contains("{{"), !remainder.contains("}}") else {
            throw ControlError("CoreDNS 模板包含未知或不完整的占位符。")
        }
    }

    func listener() throws -> [String: Any] {
        guard let listener = try JSONSerialization.jsonObject(with: Data(sslocal.utf8)) as? [String: Any] else {
            throw ControlError("sslocal 模板必须是 JSON 对象。")
        }
        // PF redirection and readiness checks depend on this listener contract.
        guard listener["protocol"] as? String == "redir",
              listener["local_address"] as? String == "127.0.0.1",
              listener["local_port"] as? Int == 59097,
              listener["mode"] as? String == "tcp_only" else {
            throw ControlError("sslocal 模板必须保留 redir、127.0.0.1:59097 和 tcp_only。")
        }
        let forbidden = ["server", "server_port", "password", "method", "servers", "locals", "plugin", "plugin_opts", "outbound_proxy"]
        guard !forbidden.contains(where: { listener[$0] != nil }) else {
            throw ControlError("sslocal 模板仅用于本地监听；服务器、凭据及插件参数请在节点配置中编辑。")
        }
        return listener
    }
}
