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
                VStack(alignment: .leading, spacing: 14) {
                    faults
                    claudeCard
                    resetsCard
                    plansCard
                    tokensCard
                    widgetPreviewSection
                    footer
                }
                .padding(16)
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

    // MARK: Faults

    /// Only what needs action or changes how far to trust the numbers. Which machine
    /// supplied a healthy reading is footer material.
    @ViewBuilder private var faults: some View {
        if let error = store.error {
            banner(error, color: UsageStyle.color(for: 100))
        }
        if let hits = store.payload?.atLimit, !hits.isEmpty {
            banner("At limit: " + hits.joined(separator: ", "), color: UsageStyle.color(for: 100))
        }
        if store.payload?.fromCache == true {
            banner(offlineMessage, color: UsageStyle.color(for: 75))
        } else if store.payload?.stale == true {
            banner(staleMessage, color: UsageStyle.color(for: 75))
        }
        // Only providers the aggregator actually reports get a row, so a setup with two
        // plans does not show four rows of "unavailable".
        if let p = store.payload, p.claude == nil, p.grok == nil, p.codex == nil,
           p.muse == nil, p.antigravity == nil {
            banner("The aggregator reports no providers. Configure at least one in its config.json.",
                   color: UsageStyle.color(for: 75))
        }
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

    // MARK: Cards

    @ViewBuilder private var claudeCard: some View {
        if let claude = store.payload?.claude {
            card {
                HStack(alignment: .firstTextBaseline) {
                    heading("Claude", UsageStyle.claude)
                    Spacer()
                    if let updated = store.payload?.updatedDate {
                        Text("as at \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(UsageStyle.faint)
                    }
                }
                if claude.ok == true, let limits = claude.limits {
                    let week = Meter(name: "Claude", color: UsageStyle.claude, percent: limits.weeklyAll?.percent,
                                     resets: limits.weeklyAll?.resetsDate, length: Meter.week)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(UsageStyle.percentText(week.percent))
                                .font(.system(size: 56, weight: .bold, design: .rounded))
                                .foregroundStyle(UsageStyle.color(for: week.percent))
                                .monospacedDigit()
                            Text("of the week used")
                                .font(.subheadline)
                                .foregroundStyle(UsageStyle.label)
                        }
                        PaceBar(percent: week.percent, pace: week.pace()).frame(height: 8)
                        detail(week, size: .subheadline)
                        if let pace = week.pace() {
                            Text("The tick on each bar is even pace, \(Int(pace.rounded()))% by now.")
                                .font(.caption)
                                .foregroundStyle(UsageStyle.faint)
                        }
                    }
                    if let s = limits.session {
                        limitRow(Meter(name: "5-hour session", color: UsageStyle.claude, percent: s.percent,
                                       resets: s.resetsDate, length: Meter.fiveHours), quiet: false)
                    }
                    if let scoped = limits.weeklyScoped {
                        limitRow(Meter(name: scoped.model ?? "Scoped model", color: UsageStyle.claude,
                                       percent: scoped.percent, resets: scoped.resetsDate, length: Meter.week),
                                 quiet: false)
                    }
                } else {
                    Text(claude.error ?? "No Claude data")
                        .font(.callout)
                        .foregroundStyle(UsageStyle.color(for: 100))
                }
            }
        }
    }

    @ViewBuilder private var resetsCard: some View {
        let resets = store.payload?.bankedResets ?? []
        if !resets.isEmpty {
            card {
                heading("Resets banked", UsageStyle.label)
                ForEach(resets) { r in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.plan)
                                .font(.body.weight(.medium))
                                .foregroundStyle(UsageStyle.label)
                            Text(([r.note.prefix(1).uppercased() + r.note.dropFirst()]
                                  + (r.expires.map { ["expires " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))] } ?? []))
                                .joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(r.urgent ? UsageStyle.codex : UsageStyle.faint)
                        }
                        Spacer(minLength: 8)
                        Text("\(r.count)")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(r.urgent ? UsageStyle.codex : Color(white: 0.92))
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// Every plan other than Claude, in the same order as the widget.
    @ViewBuilder private var plansCard: some View {
        let plans = (store.payload?.meters ?? []).filter { $0.tier > 1 }
        let notes = planNotes
        if !plans.isEmpty || !notes.isEmpty {
            card {
                heading("Other plans", UsageStyle.label)
                ForEach(plans) { limitRow($0, quiet: true) }
                ForEach(notes, id: \.0) { text, color in
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(color)
                }
            }
        }
    }

    /// What a row cannot say for itself: a provider with no reading, a frozen or stale
    /// one, and where an unusual reading came from.
    private var planNotes: [(String, Color)] {
        guard let p = store.payload else { return [] }
        let red = UsageStyle.color(for: 100), amber = UsageStyle.color(for: 75)
        var notes: [(String, Color)] = []
        if let g = p.grok, g.ok != true { notes.append(("Grok unavailable.", red)) }
        if let c = p.codex {
            if c.ok != true || c.headline == nil {
                notes.append(("Codex unavailable (\(c.error ?? "unknown")).", red))
            } else if c.frozen {
                notes.append((c.frozenNote, red))
            } else if p.codexStale == true {
                notes.append(("Codex: collector offline, may be stale.", amber))
            }
            if let credits = c.credits, credits.unlimited == true || (credits.balance ?? 0) > 0 {
                notes.append(("Codex paid credits: \(credits.text)"
                              + (credits.overageLimitReached == true ? ", overage limit reached." : "."),
                              UsageStyle.faint))
            }
        }
        if let m = p.muse {
            if m.ok != true || m.headline == nil {
                notes.append(("Muse unavailable (\(m.error ?? "unknown")).", red))
            } else if m.frozen {
                notes.append((m.error == "keychain_prompt" || m.error == "keychain_denied"
                              ? "Muse login needs Keychain approval on the collector (Always Allow)."
                              : "Muse unreachable (\(m.error ?? "unknown")), frozen \(m.readingAge.map(UsageStyle.ageText) ?? "some time") ago.",
                              red))
            } else if p.museStale == true {
                notes.append(("Muse: collector offline, may be stale.", amber))
            } else if m.source == "web" {
                notes.append(("Muse is read from dev.meta.ai while no 5-hour window is active.", UsageStyle.faint))
            }
        }
        if let a = p.antigravity {
            if a.ok != true {
                notes.append((a.error == "not_running" ? "Antigravity is not running, no reading yet."
                              : "Antigravity unavailable (\(a.error ?? "unknown")).", red))
            } else {
                if a.frozen {
                    notes.append((a.frozenNote, red))
                } else if p.antigravityStale == true {
                    notes.append(("Antigravity: collector offline, may be stale.", amber))
                }
                notes.append(("Antigravity rows show used. Its own Models screen shows what is left.",
                              UsageStyle.faint))
            }
        }
        return notes
    }

    /// Today and the last seven days per source, each row opening that source's history.
    /// All four keep a token log on disk: agy stores its per-call usage inside protobuf
    /// step metadata, which the collector decodes.
    @ViewBuilder private var tokensCard: some View {
        let p = store.payload
        let sources: [(String, TokenUsage?, String, String)] = [
            ("Claude Code", p?.tokens, "messages",
             "Claude Code sessions on the collector machine only: not claude.ai."),
            ("Codex", p?.codexTokens, "turns",
             "Codex CLI sessions on the collector machine only, read from its "
             + "session rollouts. Not the ChatGPT app. Cost uses OpenAI's published "
             + "standard-tier list prices."),
            ("Grok", p?.grokTokens, "turns",
             "Grok CLI sessions on the collector machine only, read from its "
             + "session update logs. Not grok.com chat. Cost is the figure the Grok "
             + "CLI records itself per turn."),
            ("Antigravity", p?.agyTokens, "calls",
             "agy (Antigravity CLI) and Antigravity IDE conversations on the "
             + "collector machine, decoded from their step metadata. Model names "
             + "come from a code table mapped by test runs; unmapped codes are "
             + "listed by number and left unpriced. Cost uses Gemini API and "
             + "Anthropic list prices."),
        ].filter { $0.1?.ok == true }
        if !sources.isEmpty {
            card {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    heading("Tokens", UsageStyle.label)
                    Spacer()
                    Group {
                        Text("Today")
                        Text("7 days")
                    }
                    .font(.caption)
                    .foregroundStyle(UsageStyle.faint)
                    .frame(width: 68, alignment: .trailing)
                    Color.clear.frame(width: 20, height: 1)
                }
                ForEach(sources, id: \.0) { name, tokens, unit, caveat in
                    NavigationLink {
                        TokenHistoryView(tokens: tokens!, title: "\(name) token history", unit: unit, caveat: caveat)
                    } label: {
                        HStack(spacing: 0) {
                            Text(name)
                                .font(.body.weight(.medium))
                                .foregroundStyle(UsageStyle.label)
                            Spacer()
                            ForEach([1, 7], id: \.self) { n in
                                let v = tokens!.billed(lastDays: n)
                                Text(UsageStyle.compact(v))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(v == 0 ? UsageStyle.faint : Color(white: 0.92))
                                    .monospacedDigit()
                                    .frame(width: 68, alignment: .trailing)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(UsageStyle.faint)
                                .frame(width: 20, alignment: .trailing)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let ct = p?.costTotal, let total = ct.total {
                    Divider().overlay(UsageStyle.faint.opacity(0.3))
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("All time, at API rates")
                                .font(.body.weight(.medium))
                                .foregroundStyle(UsageStyle.label)
                            Text(ct.parts?.keys.contains("grok_tokens") == true
                                 ? "Not a bill. Grok's share is the CLI's own accounting; the rest is counterfactual."
                                 : "Not a bill: flat-rate plans paid none of this.")
                                .font(.caption)
                                .foregroundStyle(UsageStyle.faint)
                        }
                        Spacer(minLength: 8)
                        Text(UsageStyle.money(total, currency: ct.currency ?? "AUD"))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(UsageStyle.claude)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// Frames match WidgetKit's real sizes on a Pro Max class phone (170 square, 364 x 170
    /// medium), inset by the same padding the widget itself uses.
    private var widgetPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Widget preview", UsageStyle.faint)
            let entry = UsageEntry(date: Date(), payload: store.payload, error: store.error)
            let mediumWidth = min(364, UIScreen.main.bounds.width - 32)
            HStack(alignment: .top, spacing: 16) {
                widgetChrome(width: 170, height: 170, padding: UsageStyle.widgetPadding) {
                    UsageWidgetView(entry: entry, family: .small)
                }
                widgetChrome(width: 172, height: 76, padding: 12) {
                    UsageWidgetView(entry: entry, family: .rectangular)
                }
            }
            widgetChrome(width: mediumWidth, height: 170, padding: UsageStyle.widgetPadding) {
                UsageWidgetView(entry: entry, family: .medium)
            }
        }
        .padding(.top, 8)
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
            // Normal several times a day: the aggregator's own token lapses between
            // Claude Code runs on its host and the collector's reading takes over.
            if store.payload?.claudeSource != nil {
                Text("Claude reading relayed by the collector"
                     + (store.payload?.claudeError.map { " (aggregator: \($0))" } ?? "")
                     + ". Fresh while the collector is awake.")
            }
        }
        .font(.caption)
        .foregroundStyle(UsageStyle.faint)
    }

    // MARK: Building blocks

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func heading(_ title: String, _ color: Color) -> some View {
        Text(title.uppercased())
            .font(.footnote.weight(.heavy))
            .foregroundStyle(color)
    }

    /// One limit: name and number, bar, then what is left and when it resets.
    private func limitRow(_ m: Meter, quiet: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(m.name == "C+GPT" ? "Claude + GPT" : m.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(UsageStyle.label)
                if let plan = m.plan {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(UsageStyle.faint)
                }
                Spacer(minLength: 8)
                Text(UsageStyle.percentText(m.percent))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(quiet ? UsageStyle.quietColor(for: m.percent) : UsageStyle.color(for: m.percent))
                    .monospacedDigit()
            }
            PaceBar(percent: m.percent, pace: m.pace()).frame(height: 5)
            detail(m, size: .footnote)
        }
    }

    /// "34% left · resets Sun 1:59 am", with a run-out warning on its own line.
    @ViewBuilder private func detail(_ m: Meter, size: Font) -> some View {
        let reset = m.expectedResets.map { _ in UsageStyle.resetText(m.resets, expected: m.expectedResets) }
            ?? UsageStyle.resetLong(m.resets)
        let parts = [m.percent.map { "\(Int((100 - $0).rounded()))% left" },
                     reset,
                     m.expectedResets.flatMap { $0 > Date() ? m.expectedWindows.map { "est. from \($0) windows" } : nil },
                     m.fiveHour.map { "5-hour \(UsageStyle.percentText($0))" },
                     m.fiveHourNote].compactMap { $0 }
        Text(parts.isEmpty ? "no data" : parts.joined(separator: " · "))
            .font(size)
            .foregroundStyle(UsageStyle.faint)
        if m.runsOut() != nil, let s = m.status() {
            Text("Runs \(s) at this rate")
                .font(size.weight(.semibold))
                .foregroundStyle(UsageStyle.color(for: 75))
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func widgetChrome<Content: View>(width: CGFloat,
                                             height: CGFloat,
                                             padding: CGFloat,
                                             @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(padding)
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
    var title: String = "Token history"
    var unit: String = "messages"
    var caveat: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                totals
                chart
                costSection
                models
                activity
                caveatView
            }
            .padding(20)
        }
        .background(UsageStyle.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                stat("Tokens", UsageStyle.compact(tokens.billed), "input + output + cache writes")
                stat(unit.capitalized, UsageStyle.grouped(tokens.messages),
                     unit == "turns"
                        ? "across \(UsageStyle.grouped(tokens.apiMessages)) sessions"
                        : "logged replies · \(UsageStyle.grouped(tokens.apiMessages)) API messages")
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

                // Grok reports one figure per model with no per-type split.
                ForEach(c.byType == nil ? [] : costTypeRows(c), id: \.0) { label, value in
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

                if let unpriced = c.unpriced, !unpriced.isEmpty {
                    Text("Unpriced: " + unpriced.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(UsageStyle.color(for: 75))
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

    /// Billed tokens by the directory each session ran from. The label is a proxy for
    /// what the work was about: fleet runs and project folders separate cleanly, but
    /// every interactive session started from the home directory shares one bucket.
    @ViewBuilder private var activity: some View {
        if let rows = tokens.byProject, !rows.isEmpty {
            let total = max(rows.reduce(0) { $0 + $1.billed }, 1)
            VStack(alignment: .leading, spacing: 10) {
                Text("BY ACTIVITY (WORKING DIRECTORY)")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(UsageStyle.gemini)
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(r.name)
                                .font(.subheadline)
                                .foregroundStyle(UsageStyle.label)
                                .lineLimit(1)
                            Spacer()
                            Text(UsageStyle.compact(r.billed))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(UsageStyle.claude)
                                .monospacedDigit()
                        }
                        ProgressView(value: Double(r.billed) / Double(total))
                            .tint(UsageStyle.gemini)
                    }
                }
            }
        }
    }

    /// "claude-haiku-4-5-20251001" -> "Haiku 4.5". Version parts are hyphenated
    /// upstream, and a trailing build date is noise. Other vendors' ids are left alone.
    private func prettyModel(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.split(separator: "-")
            .map(String.init)
            .filter { $0 != "claude" && !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        let title = name.prefix(1).uppercased() + name.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }

    @ViewBuilder private var caveatView: some View {
        if !caveat.isEmpty {
            Text(caveat)
                .font(.caption2)
                .foregroundStyle(UsageStyle.faint)
        }
    }
}
