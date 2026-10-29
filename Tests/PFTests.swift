import Foundation

func testPFVerification() throws {
    let separated = try Command.run("/usr/bin/awk", ["BEGIN { for(i=0;i<20000;i++) print \"diagnostic\" > \"/dev/stderr\"; printf \"rules\" }"], stdoutOnly: true)
    require(separated.output == "rules", "Diagnostic output must not be parsed as rules, even when stderr fills a pipe")
    do {
        _ = try Command.run("/bin/sh", ["-c", "printf diagnostic >&2; exit 7"], stdoutOnly: true)
        fatalError("Expected failed PF command")
    } catch { require(error.localizedDescription.contains("diagnostic"), "Failed read commands must retain stderr diagnostics") }
    try PFAnchorSnapshot(rules: "\n", nat: "", tables: "  ").requireEmpty()
    rejects("PF filter rules remain") { try PFAnchorSnapshot(rules: "pass out", nat: "", tables: "").requireEmpty() }
    rejects("PF NAT rules remain") { try PFAnchorSnapshot(rules: "", nat: "rdr on lo0", tables: "").requireEmpty() }
    rejects("PF tables remain") { try PFAnchorSnapshot(rules: "", nat: "", tables: "direct_cidr").requireEmpty() }
    let active = PFAnchorSnapshot(rules: "pass out route-to (lo0 127.0.0.1) inet proto tcp from any to ! <direct_cidr> flags S/SA no state\npass in on lo0 inet proto tcp from any to 127.0.0.1 port = 59097 flags S/SA no state\n",
        nat: "rdr on lo0 inet proto tcp from any to ! <direct_cidr> -> 127.0.0.1 port 59097\n", tables: "direct_cidr\n")
    try active.requireProxyRules()
    rejects("rollback PF routing rule missing") { try PFAnchorSnapshot(rules: "", nat: active.nat, tables: active.tables).requireProxyRules() }
    rejects("rollback PF redirect missing") { try PFAnchorSnapshot(rules: active.rules, nat: "", tables: active.tables).requireProxyRules() }
    let references = """
    TOKENS:
    PID      Process Name                 TOKEN                    TIMESTAMP
    22826    pfctl                        5713234049619199656      0 days 00:00:00
    22827    another PF client            18446744073709551615     2 days 01:02:03
    """
    let parsed = try PFVerification.references(references)
    require(parsed == [5_713_234_049_619_199_656, UInt64.max], "All foreign tokens and names with spaces must be parsed exactly")
    let noReferences = try PFVerification.references("No pf starter references held\n")
    require(noReferences.isEmpty, "No-reference output must be supported")
    rejects("unknown PF reference format") { _ = try PFVerification.references("unexpected output") }
    rejects("truncated PF reference output") { _ = try PFVerification.references("TOKENS:\nPID TOKEN TIMESTAMP") }
    var live: Set<UInt64> = [42, 99]
    var released: [String] = []
    try PFVerification.release("42", references: { live }, perform: { token in released.append(token); live.remove(UInt64(token)!) })
    require(live == [99] && released == ["42"], "Stop must release only its own token and preserve foreign references")
    try PFVerification.release("42", references: { live }, perform: { _ in fatalError("Already released token must not be released again") })
    live.insert(42)
    rejects("release success without token removal") { try PFVerification.release("42", references: { live }, perform: { _ in }) }
    try PFVerification.release("42", references: { live }, perform: { _ in
        live.remove(42)
        throw ControlError("Concurrent invalidation")
    })
    require(live == [99], "Confirmed token removal must make recovery idempotent despite a command error")
    rejects("reference readback failure") {
        try PFVerification.release("42", references: { throw ControlError("cannot read PF") }, perform: { _ in fatalError("Must not release an unverified reference") })
    }
    var flushed: [String] = []
    try PFVerification.clear(flush: { kind in
        flushed.append(kind)
        throw ControlError("already absent")
    }, verify: { })
    require(flushed == ["nat", "rules", "Tables"], "All cleanup steps must run even after a flush error")
    rejects("flush success without empty readback") {
        try PFVerification.clear(flush: { _ in }, verify: { throw ControlError("rule remains") })
    }
    print("PASS: PF readback, exact reference parsing, foreign references, idempotence, failure retention")
}
