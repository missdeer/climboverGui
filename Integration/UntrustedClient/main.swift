import Foundation

@objc protocol UntrustedProxyProtocol {
    func perform(_ operation: String, profile: String, service: String, additionalCIDRs: String, reply: @escaping (Data?, String?) -> Void)
}

let connection = NSXPCConnection(machServiceName: "com.dfordsoft.climbover.daemon", options: .privileged)
connection.remoteObjectInterface = NSXPCInterface(with: UntrustedProxyProtocol.self)
connection.resume()
let remote = connection.remoteObjectProxyWithErrorHandler { error in
    print("PASS: client without trusted Developer ID rejected: \(error.localizedDescription)")
    fflush(stdout)
    exit(0)
} as! UntrustedProxyProtocol
remote.perform("snapshot", profile: "", service: "", additionalCIDRs: "") { _, _ in
    FileHandle.standardError.write(Data("FAIL: untrusted client reached the privileged service\n".utf8))
    exit(1)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
    FileHandle.standardError.write(Data("INCONCLUSIVE: no XPC result before timeout\n".utf8))
    exit(2)
}
RunLoop.current.run()
