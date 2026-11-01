import Foundation

enum ConfigurationTemplateSection: String, CaseIterable, Identifiable {
    case sslocal = "sslocal · JSON"
    case coreDNS = "CoreDNS · Corefile"
    case directDomains = "直连域名 · DIRECT_DOMAINS"
    case bogusResponses = "污染响应 IP · BOGUS_RESPONSES"
    case appleDomains = "Apple 域名 · APPLE_DOMAINS"
    case blocklistFile = "屏蔽列表文件 · BLOCKLIST_FILE"

    var id: Self { self }

    var variable: RemoteTemplateVariable? {
        switch self {
        case .directDomains: return .directDomains
        case .bogusResponses: return .bogusResponses
        case .appleDomains: return .appleDomains
        case .blocklistFile: return .blocklistFile
        default: return nil
        }
    }

    var defaultText: String {
        switch self {
        case .sslocal: return ConfigurationTemplates.sslocal
        case .coreDNS: return ConfigurationTemplates.coreDNS
        case .directDomains: return ""
        case .bogusResponses: return ""
        case .appleDomains: return ""
        case .blocklistFile: return ""
        }
    }

    var help: String {
        switch self {
        case .sslocal:
            return "本地监听的 JSON 模板。保留 redir、127.0.0.1:59097 和 tcp_only；服务器、凭据及插件参数来自所选节点。"
        case .coreDNS:
            return "变量内容来自各项设置中的下载 URL 和本地缓存。Corefile 语法在启动时由 CoreDNS 检查。"
        case .blocklistFile:
            return "输入屏蔽列表的 HTTP/HTTPS URL。下载内容会缓存，并在启动时写入屏蔽列表文件。留空使用项目的 coredns/domains.txt。"
        default:
            return "输入 UTF-8 文本列表的 HTTP/HTTPS URL，每行一项或以空白分隔，支持 # 注释。留空使用内置列表。"
        }
    }

    func text(in templates: EditableTemplates) -> String {
        if self == .sslocal { return templates.sslocal }
        if self == .coreDNS { return templates.coreDNS }
        return variable.flatMap { templates.variableURLs?[$0.rawValue] } ?? ""
    }

    func update(_ text: String, in templates: inout EditableTemplates) {
        if self == .sslocal { templates.sslocal = text; return }
        if self == .coreDNS { templates.coreDNS = text; return }
        guard let variable else { return }
        var urls = templates.variableURLs ?? [:]
        urls[variable.rawValue] = text.isEmpty ? nil : text
        templates.variableURLs = urls.isEmpty ? nil : urls
    }
}
