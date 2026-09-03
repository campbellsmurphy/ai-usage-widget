import SwiftUI

enum UsageConfig {
    static let host = Secrets.aggregatorHost
    static let token = Secrets.aggregatorToken
    /// Tailscale first, then the aggregator's LAN address. The tailnet is the only
    /// route away from home, but the phone's VPN is not always up, and when it is off
    /// a 100.x address just black-holes until the request times out.
    static var hosts: [String] { [host, Secrets.aggregatorLANHost].filter { !$0.isEmpty } }
    static func url(host: String, force: Bool = false) -> URL {
        URL(string: "http://\(host)/usage.json?k=\(token)" + (force ? "&force=1" : ""))!
    }
    /// The aggregator caches for 20 minutes and is the only thing that talks to
    /// Anthropic, so refreshing on the same cadence never touches the upstream budget.
    static let refreshInterval: TimeInterval = 20 * 60
}

struct UsagePayload: Decodable {
    var claude: ClaudeUsage?
    var grok: GrokUsage?
    var gemini: GeminiUsage?
    var codex: CodexUsage?
    var antigravity: AntigravityUsage?
    var tokens: TokenUsage?
    var updated: TimeInterval?
    var stale: Bool?
    var claudeError: String?
    var claudeSource: String?
    var antigravityStale: Bool?
    var codexStale: Bool?
    /// Set locally and never decoded: this reading came off the phone's own disk cache
    /// because no route to the aggregator answered. Distinct from `stale`, which the
    /// aggregator sets when *it* is serving its last good reading. Conflating the two
    /// made a phone that simply could not reach the network report an aggregator fault.
    var fromCache: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case claude, grok, gemini, codex, antigravity, tokens, updated, stale
        case claudeError = "claude_error"
        case claudeSource = "claude_source"
        case antigravityStale = "antigravity_stale"
        case codexStale = "codex_stale"
    }

    var updatedDate: Date? { updated.map { Date(timeIntervalSince1970: $0) } }

    /// Every metric that has hit its ceiling. Surfaced loudly: at 100% the limit is
    /// actively blocking work, which is the one case worth interrupting for.
    var atLimit: [String] {
        var hits: [String] = []
        func check(_ label: String, _ pct: Double?) {
            if let p = pct, p >= 100 { hits.append(label) }
        }
        if claude?.ok == true, let l = claude?.limits {
            check("Claude 5-hour", l.session?.percent)
            check("Claude weekly", l.weeklyAll?.percent)
            check("Claude \(l.weeklyScoped?.model ?? "scoped") weekly", l.weeklyScoped?.percent)
        }
        if grok?.ok == true { check("Grok weekly", grok?.percent) }
        if codex?.ok == true {
            for w in codex?.windows ?? [] { check("Codex \(w.label ?? "limit")", w.percent) }
        }
        if antigravity?.ok == true {
            for g in antigravity?.groups ?? [] {
                let n = g.name ?? "Antigravity"
                check("\(n) weekly", g.weeklyUsed)
                check("\(n) 5-hour", g.fiveHourUsed)
            }
        }
        return hits
    }
}

struct ClaudeUsage: Decodable {
    var ok: Bool?
    var limits: Limits?
    var error: String?

    struct Limits: Decodable {
        var session: Limit?
        var weeklyAll: Limit?
        var weeklyScoped: Limit?

        enum CodingKeys: String, CodingKey {
            case session
            case weeklyAll = "weekly_all"
            case weeklyScoped = "weekly_scoped"
        }
    }

    struct Limit: Decodable {
        var percent: Double?
        var resetsAt: String?
        var model: String?

        enum CodingKeys: String, CodingKey {
            case percent
            case resetsAt = "resets_at"
            case model
        }

        var resetsDate: Date? { resetsAt.flatMap(UsageDate.parse) }
    }
}

struct GrokUsage: Decodable {
    var ok: Bool?
    var percent: Double?
    var window: String?
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case ok, percent, window
        case resetsAt = "resets_at"
    }

    var resetsDate: Date? { resetsAt.flatMap(UsageDate.parse) }

    /// This is now the weekly SuperGrok subscription quota, not the 2-hour chat
    /// limiter the aggregator used to read.
    var windowLabel: String { window == "weekly" ? "GROK wk" : "GROK" }
}

/// The ChatGPT plan quota behind Codex, relayed by the collector. Which windows exist depends
/// on the plan, so they arrive as a list rather than fixed fields.
struct CodexUsage: Decodable {
    var ok: Bool?
    var plan: String?
    var windows: [Window]?
    var error: String?
    /// Set only when the collector is replaying its last good reading.
    var readingAge: Int?

    enum CodingKeys: String, CodingKey {
        case ok, plan, windows, error
        case readingAge = "reading_age"
    }

    struct Window: Decodable, Identifiable {
        var label: String?
        var percent: Double?
        var resetsAt: String?
        /// OpenAI keeps handing out resets before the advertised time, so the aggregator
        /// estimates one from how long this window has actually been lasting. Present
        /// only while the estimate is still ahead of now and earlier than advertised.
        var expectedResetsAt: String?
        /// How many completed windows the estimate is built from.
        var expectedWindows: Int?

        enum CodingKeys: String, CodingKey {
            case label, percent
            case resetsAt = "resets_at"
            case expectedResetsAt = "expected_resets_at"
            case expectedWindows = "expected_windows"
        }

        var id: String { label ?? "window" }
        var resetsDate: Date? { resetsAt.flatMap(UsageDate.parse) }
        var expectedResetsDate: Date? { expectedResetsAt.flatMap(UsageDate.parse) }
    }

    var frozen: Bool { readingAge != nil }

    var frozenNote: String {
        let age = readingAge.map(UsageStyle.ageText) ?? "some time"
        return error == "auth_expired"
            ? "Codex login has expired on the collector, frozen \(age) ago. Run codex there to refresh it."
            : "Codex unreachable (\(error ?? "unknown")), frozen \(age) ago."
    }

    /// The headline for the widget: the weekly cap when there is one, else whatever exists.
    var headline: Window? {
        windows?.first { $0.label == "weekly" } ?? windows?.first
    }
}

struct GeminiUsage: Decodable {
    var ok: Bool?
    var percent: Double?
}

/// Antigravity's own quota panel, relayed by the collector (the only machine that can read it).
/// The upstream API reports what is *left*; the collector already inverts it to used.
struct AntigravityUsage: Decodable {
    var ok: Bool?
    var groups: [Group]?
    var error: String?
    /// Seconds since the last reading that actually came from Antigravity. Non-nil only
    /// when the collector is replaying a cached reading because the RPC was unreachable.
    var readingAge: Int?

    enum CodingKeys: String, CodingKey {
        case ok, groups, error
        case readingAge = "reading_age"
    }

    /// Antigravity quit, or its quota RPC stopped answering: the numbers below are the
    /// last known ones, not current.
    var frozen: Bool { readingAge != nil }

    var frozenNote: String {
        let age = readingAge.map(UsageStyle.ageText) ?? "some time"
        return error == "not_running"
            ? "Antigravity is not running, frozen \(age) ago."
            : "Antigravity unreachable (\(error ?? "unknown")), frozen \(age) ago."
    }

    struct Group: Decodable {
        var name: String?
        var weeklyUsed: Double?
        var weeklyResetsAt: String?
        var fiveHourUsed: Double?
        var fiveHourResetsAt: String?

        enum CodingKeys: String, CodingKey {
            case name
            case weeklyUsed = "weekly_used"
            case weeklyResetsAt = "weekly_resets_at"
            case fiveHourUsed = "five_hour_used"
            case fiveHourResetsAt = "five_hour_resets_at"
        }

        var weeklyResetsDate: Date? { weeklyResetsAt.flatMap(UsageDate.parse) }
    }

    var gemini: Group? { groups?.first { $0.name?.localizedCaseInsensitiveContains("gemini") == true } }
    var thirdParty: Group? { groups?.first { $0.name?.localizedCaseInsensitiveContains("claude") == true } }
}

/// Claude Code token history, computed from local session logs on the collector.
/// Covers the CLI only -- not claude.ai, and not Grok or Antigravity, neither of
/// which exposes token counts at all.
struct TokenUsage: Decodable {
    var ok: Bool?
    var messages: Int?
    var apiMessages: Int?
    var billed: Int?
    var cacheRead: Int?
    var input: Int?
    var output: Int?
    var cacheCreation: Int?
    var models: [String: Int]?
    var days: [Day]?
    var cost: Cost?
    var error: String?

    /// What this usage would have cost at list API rates. On a flat-rate plan this is
    /// a counterfactual, not a bill.
    struct Cost: Decodable {
        var currency: String?
        var total: Double?
        var byType: [String: Double]?
        var byModel: [ModelCost]?
        var basis: String?
        var fxStale: Bool?

        enum CodingKeys: String, CodingKey {
            case currency, total, basis
            case fxStale = "fx_stale"
            case byType = "by_type"
            case byModel = "by_model"
        }

        struct ModelCost: Decodable, Identifiable {
            var model: String
            var cost: Double
            var byType: [String: Double]?
            var id: String { model }

            enum CodingKeys: String, CodingKey {
                case model, cost
                case byType = "by_type"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case ok, messages, billed, input, output, models, days, cost, error
        case apiMessages = "api_messages"
        case cacheRead = "cache_read"
        case cacheCreation = "cache_creation"
    }

    struct Day: Decodable, Identifiable {
        var d: String
        var billed: Int
        var msgs: Int
        var id: String { d }

        var date: Date? {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f.date(from: d)
        }
    }

    var modelsSorted: [(String, Int)] {
        (models ?? [:]).sorted { $0.value > $1.value }
    }
}

enum UsageDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}

struct UsageUnreachable: LocalizedError {
    var errorDescription: String? {
        "Can't reach the aggregator. Off the tailnet (another VPN may hold the one iOS VPN "
        + "slot), off the home network, or the aggregator host is down."
    }
}

enum UsageLoader {
    /// Every route is tried at once, and the first one to answer wins. Tried in order, a
    /// dead route costs its whole timeout before the live one is even attempted: iOS runs
    /// one VPN at a time, so whenever another VPN holds the slot the tailnet address
    /// black-holes for the full 8s, which is long enough for a widget refresh to be cut
    /// off before it ever reaches the LAN address that would have answered instantly.
    static func fetch(force: Bool = false) async -> Result<UsagePayload, Error> {
        let timeout: TimeInterval = force ? 20 : 8
        let winner = await withTaskGroup(of: (Data, UsagePayload)?.self) { group in
            for host in UsageConfig.hosts {
                group.addTask {
                    var request = URLRequest(url: UsageConfig.url(host: host, force: force))
                    request.timeoutInterval = timeout
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let payload = try? JSONDecoder().decode(UsagePayload.self, from: data)
                    else { return nil }
                    return (data, payload)
                }
            }
            for await result in group where result != nil {
                group.cancelAll()
                return result
            }
            return nil
        }
        if let winner {
            UsageCache.save(winner.0)
            return .success(winner.1)
        }
        // Every route failed. Old numbers with an age on them beat a bare error string.
        if var cached = UsageCache.load() {
            cached.fromCache = true
            return .success(cached)
        }
        return .failure(UsageUnreachable())
    }
}

/// Last good reading, per target (the app and the widget each keep their own copy:
/// no App Group, which would mean new entitlements on a free-provisioning build).
enum UsageCache {
    private static var file: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("usage-last-good.json")
    }

    static func save(_ data: Data) {
        guard let file else { return }
        try? data.write(to: file, options: .atomic)
    }

    static func load() -> UsagePayload? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(UsagePayload.self, from: data)
    }
}

// MARK: - Presentation

enum UsageStyle {
    static let background = Color(red: 0.078, green: 0.063, blue: 0.055)
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let gemini = Color(red: 0.604, green: 0.659, blue: 0.780)
    static let codex = Color(red: 0.427, green: 0.800, blue: 0.667)
    static let label = Color(white: 0.81)
    static let faint = Color(white: 0.44)

    static func color(for percent: Double?) -> Color {
        guard let percent else { return Color(white: 0.47) }
        if percent >= 90 { return Color(red: 0.898, green: 0.282, blue: 0.302) }
        if percent >= 70 { return Color(red: 0.961, green: 0.651, blue: 0.137) }
        return Color(red: 0.290, green: 0.753, blue: 0.478)
    }

    static func percentText(_ percent: Double?) -> String {
        guard let percent else { return "n/a" }
        return "\(Int(percent.rounded()))%"
    }

    /// "resets 7pm" when it lands today, "resets Sat" when it is further out.
    static func resetText(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        if date <= now { return "reset due" }
        return "resets \(whenText(date, now: now))"
    }

    /// The bare "7pm" / "Sat" half of `resetText`, for composing.
    static func whenText(_ date: Date, now: Date = Date()) -> String {
        date.timeIntervalSince(now) >= 86_400
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.hour().minute())
    }

    /// The advertised reset is the provider's own upper bound; the estimate is ours.
    /// Lead with the estimate and keep the advertised date visible behind it, so this
    /// never presents a derived guess as the provider's word.
    static func resetText(_ advertised: Date?, expected: Date?, now: Date = Date()) -> String? {
        guard let expected, let advertised, expected > now else {
            return resetText(advertised, now: now)
        }
        return "~\(whenText(expected, now: now)) (says \(whenText(advertised, now: now)))"
    }

    /// 5400 -> "1h". Coarse on purpose: this only ever labels how out of date a reading is.
    static func ageText(_ seconds: Int) -> String {
        if seconds >= 86_400 { return "\(seconds / 86_400)d" }
        if seconds >= 3_600  { return "\(seconds / 3_600)h" }
        return "\(max(seconds / 60, 1))m"
    }
}

extension UsageStyle {
    /// 427_300_872 -> "427.3M". Long digit strings are unreadable at a glance.
    static func compact(_ n: Int?) -> String {
        guard let n else { return "-" }
        let d = Double(n)
        switch abs(d) {
        case 1e9...:  return String(format: "%.2fB", d/1e9)
        case 1e6...:  return String(format: "%.1fM", d/1e6)
        case 1e3...:  return String(format: "%.1fk", d/1e3)
        default:      return "\(n)"
        }
    }

    static func grouped(_ n: Int?) -> String {
        guard let n else { return "-" }
        return n.formatted(.number.grouping(.automatic))
    }
}

extension UsageStyle {
    /// "A$13,903" / "A$5.52": whole dollars once the figure is large enough that
    /// cents stop carrying information.
    static func money(_ v: Double?, currency: String = "AUD") -> String {
        guard let v else { return "-" }
        let symbol = currency == "AUD" ? "A$" : (currency == "USD" ? "$" : "")
        if abs(v) >= 100 {
            return symbol + v.formatted(.number.precision(.fractionLength(0)))
        }
        return symbol + v.formatted(.number.precision(.fractionLength(2)))
    }
}
