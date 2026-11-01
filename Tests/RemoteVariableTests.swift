import Foundation

private final class VariableDownloadProtocol: URLProtocol {
    static var status = 200
    static var body = Data("direct.example\n".utf8)
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func testRemoteVariables() throws {
    let completed = DispatchSemaphore(value: 0)
    var result: Result<Void, Error> = .success(())
    Task.detached {
        do { try await checkRemoteVariables() }
        catch { result = .failure(error) }
        completed.signal()
    }
    completed.wait()
    try result.get()
}

private func checkRemoteVariables() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [VariableDownloadProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let url = "https://example.com/domains.txt"
    VariableDownloadProtocol.requests = 0
    VariableDownloadProtocol.status = 200
    VariableDownloadProtocol.body = Data("\u{feff}# domain list\ndirect.example # note\nsecond.example\n".utf8)
    var settings = EditableTemplates(variableURLs: ["DIRECT_DOMAINS": url])
    let resolved = try await RemoteTemplateVariables.resolve(settings, directory: directory, session: session)
    require(resolved.dnsVariables?.directDomains?.contains("second.example") == true, "An uncached URL must be downloaded automatically")
    let original = try RemoteTemplateVariables.cached(.directDomains, source: url, directory: directory)
    require(original != nil && original?.content.contains("#") == false, "Validated UTF-8 lists must be cached on disk with comments removed")
    VariableDownloadProtocol.status = 503
    let offline = try await RemoteTemplateVariables.resolve(settings, directory: directory, session: session)
    require(offline == resolved && VariableDownloadProtocol.requests == 1, "Startup must use persistent cache without requiring network access")
    do {
        _ = try await RemoteTemplateVariables.download(.directDomains, source: url, directory: directory, session: session)
        throw ControlError("Expected HTTP failure")
    } catch { require(error.localizedDescription.contains("503"), "HTTP failures must be reported") }
    let afterFailure = try RemoteTemplateVariables.cached(.directDomains, source: url, directory: directory)
    require(afterFailure == original, "A failed refresh must preserve the previous cache")
    VariableDownloadProtocol.status = 200
    VariableDownloadProtocol.body = Data("refreshed.example\n".utf8)
    _ = try await RemoteTemplateVariables.download(.directDomains, source: url, directory: directory, session: session)
    let refreshed = try await RemoteTemplateVariables.resolve(settings, directory: directory, session: session)
    require(refreshed.dnsVariables?.directDomains == "refreshed.example\n", "Explicit refresh must replace content used by the next start")
    let missing = try RemoteTemplateVariables.cached(.directDomains, source: "https://example.com/new.txt", directory: directory)
    require(missing == nil, "A changed URL must never reuse another URL's cache")
    let good = try RemoteTemplateVariables.cached(.directDomains, source: url, directory: directory)
    for invalid in [Data("not a domain { }".utf8), Data([0xff, 0xfe]), Data(), Data(repeating: 97, count: RemoteTemplateVariables.maximumDownloadBytes + 1)] {
        VariableDownloadProtocol.body = invalid
        do {
            _ = try await RemoteTemplateVariables.download(.directDomains, source: url, directory: directory, session: session)
            fatalError("Invalid download was accepted")
        } catch { }
        let retained = try RemoteTemplateVariables.cached(.directDomains, source: url, directory: directory)
        require(retained == good, "Invalid downloads must not overwrite a valid cache")
    }
    VariableDownloadProtocol.body = Data("blocked.example\n".utf8)
    settings.variableURLs = ["BLOCKLIST_FILE": "http://example.com/blocklist.txt"]
    let blocklist = try await RemoteTemplateVariables.resolve(settings, directory: directory, session: session)
    require(blocklist.dnsVariables?.blocklistContent == "blocked.example\n", "HTTP blocklists must resolve to contents rather than a remote file path")
    VariableDownloadProtocol.body = Data((ConfigurationTemplates.directDomains + "\ncustom.example").utf8)
    let large = try await RemoteTemplateVariables.download(.directDomains, source: url, directory: directory, session: session)
    require(large.content.contains("custom.example"), "A full direct-domain list must fit in the download and transport limits")
    print("PASS: automatic URL downloads, HTTP failures, offline disk cache, refresh, source isolation, UTF-8 validation, limits and large lists")
}
