import Foundation

private final class VariableDownloadProtocol: URLProtocol {
    static var status = 200
    static var body = Data("direct.example\n".utf8)
    static var requests = 0
    static var lastURL: URL?
    static var bodies: [String: Data] = [:]
    static var holdOpen = false
    static var sendsContentLength = true
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        Self.lastURL = request.url
        let body = Self.bodies[request.url!.absoluteString] ?? Self.body
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.sendsContentLength ? ["Content-Length": String(body.count)] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.holdOpen {
            client?.urlProtocol(self, didLoad: Data(body.prefix(128 * 1024)))
            return
        }
        client?.urlProtocol(self, didLoad: body)
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
    let localURLs = Dictionary(uniqueKeysWithValues: RemoteTemplateVariable.allCases.map { ($0.rawValue, "") })
    var settings = EditableTemplates(variableURLs: localURLs.merging(["DIRECT_DOMAINS": url]) { _, new in new })
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
    settings.variableURLs = localURLs.merging(["BLOCKLIST_FILE": "http://example.com/blocklist.txt"]) { _, new in new }
    let blocklist = try await RemoteTemplateVariables.resolve(settings, directory: directory, session: session)
    require(blocklist.dnsVariables?.blocklistContent == "blocked.example\n", "HTTP blocklists must resolve to contents rather than a remote file path")
    VariableDownloadProtocol.body = Data((ConfigurationTemplates.directDomains + "\ncustom.example").utf8)
    let large = try await RemoteTemplateVariables.download(.directDomains, source: url, directory: directory, session: session)
    require(large.content.contains("custom.example"), "A full direct-domain list must fit in the download and transport limits")
    for knownSize in [true, false] {
        try await testDownloadCancellation(directory: directory, session: session, url: url, knownSize: knownSize)
    }
    try await testDefaultDownloads(directory: directory, session: session, localURLs: localURLs)
    print("PASS: automatic URL downloads, HTTP failures, offline disk cache, refresh, source isolation, UTF-8 validation, limits, incremental progress, cancellation and large lists")
}

private func testDownloadCancellation(directory: URL, session: URLSession, url: String, knownSize: Bool) async throws {
    let beforeCancel = try RemoteTemplateVariables.cached(.directDomains, source: url, directory: directory)
    let started = DispatchSemaphore(value: 0)
    VariableDownloadProtocol.holdOpen = true
    VariableDownloadProtocol.sendsContentLength = knownSize
    let expectedSize = knownSize ? Int64(VariableDownloadProtocol.body.count) : nil
    let cancelled = Task.detached {
        try await RemoteTemplateVariables.download(.directDomains, source: url, directory: directory, session: session, progress: { value in
            if value.receivedBytes > 0 {
                require(value.totalBytes == expectedSize, "Progress must distinguish known and unknown content lengths")
                started.signal()
            }
        })
    }
    require(started.wait(timeout: .now() + 5) == .success, "Incremental progress must arrive before the download finishes")
    cancelled.cancel()
    do {
        _ = try await cancelled.value
        fatalError("A cancelled download was accepted")
    } catch {
        require(error is CancellationError || (error as? URLError)?.code == .cancelled, "Cancelling must terminate the active network request")
    }
    VariableDownloadProtocol.holdOpen = false
    VariableDownloadProtocol.sendsContentLength = true
    let afterCancel = try RemoteTemplateVariables.cached(.directDomains, source: url, directory: directory)
    require(afterCancel == beforeCancel, "Cancellation must preserve the previous cache")
}

private func testDefaultDownloads(directory: URL, session: URLSession, localURLs: [String: String]) async throws {
    VariableDownloadProtocol.body = Data("default-blocked.example\n".utf8)
    VariableDownloadProtocol.bodies = [
        RemoteTemplateVariable.directDomains.defaultURL: Data("server=/china.example/114.114.114.114\n".utf8),
        RemoteTemplateVariable.bogusResponses.defaultURL: Data("bogus-nxdomain=192.0.2.1\n".utf8),
        RemoteTemplateVariable.appleDomains.defaultURL: Data("server=/apple.example/114.114.114.114\n".utf8)
    ]
    let defaults = try await RemoteTemplateVariables.resolve(EditableTemplates(), directory: directory, session: session)
    require(VariableDownloadProtocol.lastURL?.absoluteString == RemoteTemplateVariable.blocklistFile.defaultURL, "Default resolution must download the configured blocklist URL")
    require(defaults.dnsVariables?.blocklistContent == "default-blocked.example\n", "Default blocklist downloads must supply the runtime file content")
    require(defaults.dnsVariables?.directDomains == "china.example\n" && defaults.dnsVariables?.bogusResponses == "192.0.2.1\n" && defaults.dnsVariables?.appleDomains == "apple.example\n", "All default dnsmasq downloads must be converted to runtime lists")
    let requests = VariableDownloadProtocol.requests
    _ = try await RemoteTemplateVariables.resolve(EditableTemplates(), directory: directory, session: session)
    require(VariableDownloadProtocol.requests == requests, "The default blocklist must reuse its disk cache")
    let local = try await RemoteTemplateVariables.resolve(EditableTemplates(variableURLs: localURLs), directory: directory, session: session)
    require(local.dnsVariables?.blocklistContent == nil && VariableDownloadProtocol.requests == requests, "An empty blocklist URL must use the local file without downloading or reusing the default cache")
}
