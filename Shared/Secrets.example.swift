import Foundation

/// Copy this file to `Secrets.swift` and fill in your own values.
/// `Secrets.swift` is gitignored. It must never be committed.
enum Secrets {
    /// host:port of the aggregator, reachable over the tailnet.
    static let aggregatorHost = "100.x.x.x:8756"
    /// Shared token the aggregator requires on every request.
    static let aggregatorToken = "REPLACE_ME"
    /// host:port on the home LAN, used when the tailnet route is down. "" to disable.
    static let aggregatorLANHost = "192.168.x.x:8756"
}
