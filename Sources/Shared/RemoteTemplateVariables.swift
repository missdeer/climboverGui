import Foundation
import CryptoKit

enum RemoteTemplateVariable: String, CaseIterable, Identifiable {
    case directDomains = "DIRECT_DOMAINS"
    case bogusResponses = "BOGUS_RESPONSES"
    case appleDomains = "APPLE_DOMAINS"
    case blocklistFile = "BLOCKLIST_FILE"

    var id: String { rawValue }

    var defaultURL: String {
        switch self {
        case .directDomains: return "https://github.com/felixonmars/dnsmasq-china-list/raw/refs/heads/master/accelerated-domains.china.conf"
        case .bogusResponses: return "https://github.com/felixonmars/dnsmasq-china-list/raw/refs/heads/master/bogus-nxdomain.china.conf"
        case .appleDomains: return "https://github.com/felixonmars/dnsmasq-china-list/raw/refs/heads/master/apple.china.conf"
        case .blocklistFile: return "https://github.com/missdeer/blocklist/raw/refs/heads/master/convert/alldomains.txt"
        }
    }

    func source(in templates: EditableTemplates) -> String {
        templates.variableURLs?[rawValue] ?? defaultURL
    }

    var contentKey: WritableKeyPath<DNSVariables, String?> {
        switch self {
        case .directDomains: return \.directDomains
        case .bogusResponses: return \.bogusResponses
        case .appleDomains: return \.appleDomains
        case .blocklistFile: return \.blocklistContent
        }
    }

    func validatedContent(_ text: String) throws -> String {
        // Plain domain/IP lists commonly include blank lines and # comments.
        let content = try self == .blocklistFile ? text : text.components(separatedBy: .newlines)
            .map { try normalizedLine($0) }
            .joined(separator: "\n")
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError("下载的 \(rawValue) 内容为空。")
        }
        var variables = DNSVariables()
        variables[keyPath: contentKey] = content
        try variables.validate()
        return content
    }

    private func normalizedLine(_ line: String) throws -> String {
        let content = String(line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        if self == .bogusResponses, trimmed.hasPrefix("bogus-nxdomain=") {
            let address = String(trimmed.dropFirst("bogus-nxdomain=".count))
            guard isIPAddress(address) else { throw ControlError("bogus-nxdomain 必须包含有效的 IP 地址。") }
            return address
        }
        if (self == .directDomains || self == .appleDomains), trimmed.hasPrefix("server=/") {
            let fields = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[1].isEmpty, isIPAddress(String(fields[2])) else {
                throw ControlError("域名列表中的 dnsmasq server 行格式无效。")
            }
            return String(fields[1])
        }
        return content
    }
}

struct DownloadedTemplateVariable: Codable, Equatable {
    let url: String
    let content: String
    let downloadedAt: Date
}

enum RemoteTemplateVariables {
    static let maximumDownloadBytes = 30 * 1024 * 1024
    static var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClimbOver/TemplateCache", isDirectory: true)
    }

    static func sourceURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, !text.contains(where: { $0.isWhitespace || $0 == "\0" }) else {
            throw ControlError("变量下载地址必须是有效的 HTTP 或 HTTPS URL。")
        }
        return url
    }

    static func validateURLs(_ sources: [String: String]) throws {
        for (key, source) in sources {
            guard RemoteTemplateVariable(rawValue: key) != nil else { throw ControlError("未知的模板变量：\(key)") }
            if !source.isEmpty { _ = try sourceURL(source) }
        }
    }

    private static func cacheFile(_ variable: RemoteTemplateVariable, source: String, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(variable.rawValue)-\(digest).json")
    }

    static func cached(_ variable: RemoteTemplateVariable, source: String, directory: URL = cacheDirectory) throws -> DownloadedTemplateVariable? {
        let file = cacheFile(variable, source: source, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let cache = try JSONDecoder().decode(DownloadedTemplateVariable.self, from: Data(contentsOf: file))
        guard cache.url == source, cache.content.utf8.count <= maximumDownloadBytes else {
            throw ControlError("变量缓存无效，请重新下载。")
        }
        _ = try variable.validatedContent(cache.content)
        return cache
    }

    static func download(_ variable: RemoteTemplateVariable, source: String, directory: URL = cacheDirectory,
                         session: URLSession = .shared,
                         progress: (@Sendable (VariableDownloadProgress) -> Void)? = nil) async throws -> DownloadedTemplateVariable {
        var request = URLRequest(url: try sourceURL(source), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        progress?(VariableDownloadProgress(receivedBytes: 0, totalBytes: nil))
        let delegate = TemplateVariableDownload(report: progress)
        let (data, response) = try await delegate.load(request, configuration: session.configuration)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw ControlError("下载 \(variable.rawValue) 失败，HTTP 状态：\((response as? HTTPURLResponse)?.statusCode ?? 0)。")
        }
        _ = try sourceURL(response.url?.absoluteString ?? "")
        guard data.count <= maximumDownloadBytes else { throw ControlError("单份变量内容不能超过 30 MB。") }
        try Task.checkCancellation()
        progress?(VariableDownloadProgress(receivedBytes: Int64(data.count), totalBytes: Int64(data.count)))
        guard let text = String(data: data, encoding: .utf8) else { throw ControlError("下载内容必须是 UTF-8 文本。") }
        let cleaned = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        let content = try variable.validatedContent(cleaned)
        let cache = DownloadedTemplateVariable(url: source, content: content, downloadedAt: Date())
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(cache)
        try Task.checkCancellation()
        try encoded.write(to: cacheFile(variable, source: source, directory: directory), options: .atomic)
        return cache
    }

    static func resolve(_ templates: EditableTemplates, directory: URL = cacheDirectory, session: URLSession = .shared,
                        progress: (@Sendable (RemoteTemplateVariable, VariableDownloadProgress) -> Void)? = nil) async throws -> EditableTemplates {
        try templates.validate()
        var result = templates
        var variables = templates.dnsVariables ?? DNSVariables()
        for variable in RemoteTemplateVariable.allCases {
            try Task.checkCancellation()
            let source = variable.source(in: templates)
            guard !source.isEmpty else { continue }
            let content: String
            if let cache = try? cached(variable, source: source, directory: directory) { content = cache.content }
            else {
                content = try await download(variable, source: source, directory: directory, session: session,
                    progress: { progress?(variable, $0) }).content
            }
            variables[keyPath: variable.contentKey] = content
        }
        result.dnsVariables = variables == DNSVariables() ? nil : variables
        _ = try result.encoded()
        return result
    }
}
