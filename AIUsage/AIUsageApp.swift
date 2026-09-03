import Charts
import SwiftUI
import WidgetKit

@main
struct AIUsageApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
@Observable
final class UsageStore {
    var payload: UsagePayload?
    var error: String?
    var isLoading = false
    var lastFetched: Date?

    /// A cold launch used to render an empty screen until the network answered, which
    /// away from home means waiting out the whole 8s timeout before a single number
    /// appears. The last good reading is already on disk, so paint it straight away and
    /// let the fetch replace it. `lastFetched` is deliberately left nil: the footer then
    /// shows the cached reading's own timestamp and no "Fetched" line, so a stored
    /// reading is never dressed up as one this launch actually made.
    init() {
        if var cached = UsageCache.load() {
            cached.fromCache = true
            payload = cached
        }
    }

    func load(force: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        switch await UsageLoader.fetch(force: force) {
        case .success(let payload):
            self.payload = payload
            self.error = nil
            self.lastFetched = Date()
            // The widget has no other way to learn the app just fetched; without this
            // it waits out its own 20-minute timeline.
            WidgetCenter.shared.reloadAllTimelines()
        case .failure(let error):
            self.error = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @State private var store = UsageStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = store.error {
                        banner(error, color: UsageStyle.color(for: 100))
                    }
                    if let hits = store.payload?.atLimit, !hits.isEmpty {
                        banner("AT LIMIT: " + hits.joined(separator: ", "),
                               color: UsageStyle.color(for: 100))
                    }
                    if store.payload?.fromCache == true {
                        banner(offlineMessage, color: UsageStyle.color(for: 75))
                    } else if store.payload?.stale == true {
                        banner(staleMessage, color: UsageStyle.color(for: 75))
                    }
                    if store.payload?.claudeSource != nil {
                        banner("Claude is being relayed from the collector because the aggregator can't authenticate"
                               + (store.payload?.claudeError.map { " (\($0))" } ?? "")
                               + ". Fresh while the collector is awake.", color: UsageStyle.gemini)
                    }

                    // Only providers the aggregator actually reports get a section, so a
                    // setup with two plans does not show four rows of "unavailable".
                    if let p = store.payload, p.claude == nil, p.grok == nil, p.codex == nil,
                       p.antigravity == nil {
                        banner("The aggregator reports no providers. Configure at least one in its config.json.",
                               color: UsageStyle.color(for: 75))
                    }
                    if store.payload?.claude != nil { claudeSection }
                    if store.payload?.grok != nil { grokSection }
                    if store.payload?.codex != nil { codexSection }
                    if store.payload?.antigravity != nil { antigravitySection }
                    historyLink
                    widgetPreviewSection
                    footer
                }
                .padding(20)
            }
            .background(UsageStyle.background)
            .navigationTitle("AI Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.load(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .refreshable { await store.load(force: true) }
        }
        .task { await store.load() }
    }

    /// The phone could not reach the aggregator at all. The old wording blamed the
    /// aggregator for what is a route problem at this end (off the tailnet, or another
    /// VPN holding iOS's single tunnel slot), which points at the wrong machine.
    private var offlineMessage: String {
        let age = store.payload?.updatedDate
            .map { " from \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return "Can't reach the aggregator. Showing the last reading\(age) held on this phone."
    }

    private var staleMessage: String {
        let reason = store.payload?.claudeError.map { " (\($0))" } ?? ""
        return "Aggregator is serving a cached reading\(reason). These numbers may not be current."
    }

    // MARK: Sections

    @ViewBuilder private var claudeSection: some View {
        let claude = store.payload?.claude
        section("Claude", accent: UsageStyle.claude) {
            if let limits = claude?.limits, claude?.ok == true {
                limitRow("5-hour session", limits.session)
                limitRow("Weekly, all models", limits.weeklyAll)
                limitRow(limits.weeklyScoped?.model.map { "Weekly, \($0)" } ?? "Weekly, scoped",
                         limits.weeklyScoped)
            } else {
                Text(claude?.error ?? "No Claude data")
                    .font(.callout)
                    .foregroundStyle(UsageStyle.color(for: 100))
            }
        }
    }

    @ViewBuilder private var grokSection: some View {
        section("Grok", accent: UsageStyle.label) {
            let grok = store.payload?.grok
            row(title: grok?.window == "weekly" ? "Weekly SuperGrok" : "Grok",
                subtitle: grokSubtitle,
                percent: (grok?.ok == true) ? grok?.percent : nil)
        }
    }

    private var grokSubtitle: String {
        guard let grok = store.payload?.grok, grok.ok == true else { return "Unavailable" }
        var parts: [String] = []
        if let p = grok.percent { parts.append("\(Int((100 - p).rounded()))% left") }
        if let text = UsageStyle.resetText(grok.resetsDate) { parts.append(text) }
        return parts.isEmpty ? "Weekly SuperGrok limit" : parts.joined(separator: " · ")
    }

    @ViewBuilder private var codexSection: some View {
        let codex = store.payload?.codex
        section(codex?.plan.map { "Codex (ChatGPT \($0))" } ?? "Codex", accent: UsageStyle.codex) {
            if codex?.ok == true, let windows = codex?.windows, !windows.isEmpty {
                ForEach(windows) { w in
                    bucketRow(w.label == "weekly" ? "Weekly limit" : "5-hour limit",
                              w.percent, w.resetsDate, expected: w.expectedResetsDate,
                              expectedWindows: w.expectedWindows)
                }
                if let codex, codex.frozen {
                    Text(codex.frozenNote)
                        .font(.caption2)
                        .foregroundStyle(UsageStyle.color(for: 95))
                } else if store.payload?.codexStale == true {
                    Text("Collector offline, these may be stale.")
                        .font(.caption2)
                        .foregroundStyle(UsageStyle.color(for: 75))
                }
            } else {
                Text("Codex unavailable (\(codex?.error ?? "unknown"))")
                    .font(.callout)
                    .foregroundStyle(UsageStyle.color(for: 100))
            }
        }
    }

    @ViewBuilder private var antigravitySection: some View {
        let ag = store.payload?.antigravity
        section("Antigravity", accent: UsageStyle.gemini) {
            Text("Percentages here are USED. Antigravity's own Models screen shows the "
                 + "inverse (what is left), so 0% used there reads as 100%.")
                .font(.caption2)
                .foregroundStyle(UsageStyle.faint)

            if ag?.ok == true {
                let cgWeekly = ag?.thirdParty?.weeklyUsed
                let cgWeeklyMaxed = (cgWeekly ?? 0) >= 100
                bucketRow("Claude + GPT, weekly", cgWeekly, ag?.thirdParty?.weeklyResetsDate)
                // Once the weekly is exhausted the 5-hour bucket can't be spent, so its
                // 0%-used reading is meaningless, so show n/a rather than a fresh-looking bucket.
                bucketRow("Claude + GPT, 5-hour",
                          cgWeeklyMaxed ? nil : ag?.thirdParty?.fiveHourUsed,
                          nil,
                          nilNote: cgWeeklyMaxed ? "weekly maxed" : nil)
                Divider().overlay(UsageStyle.faint.opacity(0.3))
                bucketRow("Gemini models, weekly", ag?.gemini?.weeklyUsed, ag?.gemini?.weeklyResetsDate)
                bucketRow("Gemini models, 5-hour", ag?.gemini?.fiveHourUsed, nil)
                if let ag, ag.frozen {
                    Text(ag.frozenNote)
                        .font(.caption2)
                        .foregroundStyle(UsageStyle.color(for: 95))
                } else if store.payload?.antigravityStale == true {
                    Text("Collector offline, these may be stale.")
                        .font(.caption2)
                        .foregroundStyle(UsageStyle.color(for: 75))
                }
            } else {
                // No cached reading to fall back on either, so there is genuinely
                // nothing to show.
                Text(ag?.error == "not_running"
                     ? "Antigravity is not running, no reading yet."
                     : "Antigravity unavailable (\(ag?.error ?? "unknown"))")
                    .font(.callout)
                    .foregroundStyle(UsageStyle.color(for: 100))
            }
        }
    }

    /// Shows used and left together, so this screen can never look like it contradicts
    /// Antigravity's own display.
    private func bucketRow(_ title: String, _ used: Double?, _ resets: Date?,
                           expected: Date? = nil, expectedWindows: Int? = nil,
                           nilNote: String? = nil) -> some View {
        var parts: [String] = []
        if let used { parts.append("\(Int((100 - used).rounded()))% left") }
        if let text = UsageStyle.resetText(resets, expected: expected) { parts.append(text) }
        if let expected, let expectedWindows, expected > Date() {
            parts.append("est. from \(expectedWindows) windows")
        }
        return VStack(alignment: .leading, spacing: 8) {
            row(title: title,
                subtitle: parts.isEmpty ? (nilNote ?? "no data") : parts.joined(separator: " · "),
                percent: used)
            ProgressView(value: min((used ?? 0) / 100, 1))
                .tint(UsageStyle.color(for: used))
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private var historyLink: some View {
        if let t = store.payload?.tokens, t.ok == true {
            NavigationLink {
                TokenHistoryView(tokens: t)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Token history")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(UsageStyle.label)
                        Text("\(UsageStyle.compact(t.billed)) tokens · \(UsageStyle.grouped(t.messages)) messages")
                            .font(.caption2)
                            .foregroundStyle(UsageStyle.faint)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(UsageStyle.faint)
                }
                .padding(14)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var widgetPreviewSection: some View {
        section("Widget preview", accent: UsageStyle.label) {
            let entry = UsageEntry(date: Date(), payload: store.payload, error: store.error)
            HStack(alignment: .top, spacing: 16) {
                widgetChrome(width: 158, height: 158) {
                    UsageWidgetView(entry: entry, family: .small)
                }
                VStack(alignment: .leading, spacing: 16) {
                    widgetChrome(width: 170, height: 74) {
                        UsageWidgetView(entry: entry, family: .rectangular)
                    }
                }
            }
            widgetChrome(width: 338, height: 158) {
                UsageWidgetView(entry: entry, family: .medium)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let updated = store.payload?.updatedDate {
                Text("Aggregator reading: \(updated.formatted(date: .abbreviated, time: .shortened))")
            }
            if let fetched = store.lastFetched {
                Text("Fetched: \(fetched.formatted(date: .omitted, time: .standard))")
            }
            Text("Source: \(UsageConfig.host)")
        }
        .font(.caption2)
        .foregroundStyle(UsageStyle.faint)
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: String,
                                        accent: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.heavy))
                .foregroundStyle(accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func limitRow(_ title: String, _ limit: ClaudeUsage.Limit?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row(title: title,
                subtitle: UsageStyle.resetText(limit?.resetsDate) ?? "no reset time",
                percent: limit?.percent)
            ProgressView(value: min((limit?.percent ?? 0) / 100, 1))
                .tint(UsageStyle.color(for: limit?.percent))
        }
        .padding(.bottom, 6)
    }

    private func row(title: String, subtitle: String, percent: Double?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(UsageStyle.label)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(UsageStyle.faint)
            }
            Spacer(minLength: 8)
            Text(UsageStyle.percentText(percent))
                .font(.title3.weight(.bold))
                .foregroundStyle(UsageStyle.color(for: percent))
                .monospacedDigit()
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func widgetChrome<Content: View>(width: CGFloat,
                                             height: CGFloat,
                                             @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(UsageStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(UsageStyle.faint.opacity(0.35)))
    }
}


/// Claude Code usage over time. Deliberately app-only: the widget stays a glance
/// surface, and none of this belongs on a home screen.
struct TokenHistoryView: View {
    let tokens: TokenUsage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                totals
                chart
                costSection
                models
                caveat
            }
            .padding(20)
        }
        .background(UsageStyle.background)
        .navigationTitle("Token history")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                stat("Tokens", UsageStyle.compact(tokens.billed), "input + output + cache writes")
                stat("Messages", UsageStyle.grouped(tokens.messages),
                     "logged replies · \(UsageStyle.grouped(tokens.apiMessages)) API messages")
            }
            HStack(alignment: .top, spacing: 14) {
                stat("Cache reads", UsageStyle.compact(tokens.cacheRead), "cheap, excluded above")
                stat("Output", UsageStyle.compact(tokens.output), "tokens generated")
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(UsageStyle.faint)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(UsageStyle.claude)
                .monospacedDigit()
            Text(note)
                .font(.caption2)
                .foregroundStyle(UsageStyle.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var chart: some View {
        let days = (tokens.days ?? []).compactMap { d -> (Date, Int)? in
            guard let dt = d.date else { return nil }
            return (dt, d.billed)
        }
        if days.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                Text("DAILY TOKENS")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(UsageStyle.gemini)
                Chart {
                    ForEach(days, id: \.0) { day, billed in
                        BarMark(x: .value("Day", day, unit: .day),
                                y: .value("Tokens", billed))
                            .foregroundStyle(UsageStyle.claude)
                    }
                }
                .frame(height: 190)
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine().foregroundStyle(UsageStyle.faint.opacity(0.25))
                        AxisValueLabel {
                            if let n = v.as(Int.self) { Text(UsageStyle.compact(n)) }
                        }
                    }
                }
            }
        }
    }

    /// Counterfactual API cost. Labelled hard as "would have cost", because on a
    /// flat-rate plan nobody paid this.
    @ViewBuilder private var costSection: some View {
        if let c = tokens.cost, let total = c.total {
            let cur = c.currency ?? "AUD"
            VStack(alignment: .leading, spacing: 10) {
                Text("IF BILLED AT API RATES")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(UsageStyle.gemini)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageStyle.money(total, currency: cur))
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(UsageStyle.claude)
                        .monospacedDigit()
                    Text(cur)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(UsageStyle.faint)
                }

                Text("You did not pay this. It is what the same tokens would have cost "
                     + "on pay-as-you-go API pricing instead of your plans.")
                    .font(.caption2)
                    .foregroundStyle(UsageStyle.faint)

                if c.fxStale == true {
                    Text("Exchange rate could not be refreshed, converted at a cached rate.")
                        .font(.caption2)
                        .foregroundStyle(UsageStyle.color(for: 75))
                }

                Divider().overlay(UsageStyle.faint.opacity(0.3))

                ForEach(costTypeRows(c), id: \.0) { label, value in
                    HStack {
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(UsageStyle.label)
                        Spacer()
                        Text(UsageStyle.money(value, currency: cur))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(UsageStyle.claude)
                            .monospacedDigit()
                    }
                }

                if let rows = c.byModel, !rows.isEmpty {
                    Divider().overlay(UsageStyle.faint.opacity(0.3))
                    ForEach(rows) { r in
                        HStack {
                            Text(prettyModel(r.model))
                                .font(.subheadline)
                                .foregroundStyle(UsageStyle.label)
                            Spacer()
                            Text(UsageStyle.money(r.cost, currency: cur))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(UsageStyle.claude)
                                .monospacedDigit()
                        }
                    }
                }

                if let basis = c.basis {
                    Text(basis)
                        .font(.caption2)
                        .foregroundStyle(UsageStyle.faint)
                }
            }
        }
    }

    /// Fixed order, cheapest-per-token last, so the cache-read line reads as the
    /// volume story rather than looking like the biggest expense by rate.
    private func costTypeRows(_ c: TokenUsage.Cost) -> [(String, Double)] {
        let t = c.byType ?? [:]
        return [("Input", t["input"] ?? 0),
                ("Output", t["output"] ?? 0),
                ("Cache writes", t["cache_write"] ?? 0),
                ("Cache reads", t["cache_read"] ?? 0)]
    }

    @ViewBuilder private var models: some View {
        let rows = tokens.modelsSorted.filter { !$0.0.hasPrefix("<") }
        if !rows.isEmpty {
            let total = max(rows.reduce(0) { $0 + $1.1 }, 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("BY MODEL")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(UsageStyle.gemini)
                ForEach(rows, id: \.0) { name, count in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(prettyModel(name))
                                .font(.subheadline)
                                .foregroundStyle(UsageStyle.label)
                            Spacer()
                            Text(UsageStyle.grouped(count))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(UsageStyle.claude)
                                .monospacedDigit()
                        }
                        ProgressView(value: Double(count) / Double(total))
                            .tint(UsageStyle.claude)
                    }
                }
            }
        }
    }

    /// "claude-haiku-4-5-20251001" -> "Haiku 4.5". Version parts are hyphenated
    /// upstream, and a trailing build date is noise.
    private func prettyModel(_ id: String) -> String {
        let parts = id.split(separator: "-")
            .map(String.init)
            .filter { $0 != "claude" && !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        let title = name.prefix(1).uppercased() + name.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }

    private var caveat: some View {
        Text("Claude Code sessions on the collector machine only: not claude.ai, and not "
             + "Grok or Antigravity, which report percentages but no token counts.")
            .font(.caption2)
            .foregroundStyle(UsageStyle.faint)
    }
}
