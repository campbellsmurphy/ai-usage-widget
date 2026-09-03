import SwiftUI

/// The rendered widget content. Lives in Shared so the app can show a true-to-life
/// preview at each size without duplicating layout code.
struct UsageWidgetView: View {
    var entry: UsageEntry
    var family: UsageWidgetFamily

    var body: some View {
        switch family {
        case .small: small
        case .medium: medium
        case .rectangular: rectangular
        }
    }

    private var claude: ClaudeUsage? {
        guard let claude = entry.payload?.claude, claude.ok == true else { return nil }
        return claude
    }

    // MARK: Sizes

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasClaude {
                if let limits = claude?.limits {
                    header("CLAUDE", color: UsageStyle.claude)
                    Spacer(minLength: 3)
                    metric("5-hour", limits.session?.percent)
                    metric("Weekly", limits.weeklyAll?.percent)
                    metric(limits.weeklyScoped?.model ?? "Scoped", limits.weeklyScoped?.percent)
                    Spacer(minLength: 5)
                } else {
                    unavailable("CLAUDE", entry.payload?.claude?.error)
                }
            }
            if hasGrok {
                providerRow(entry.payload?.grok?.windowLabel ?? "GROK", grokPercent, UsageStyle.label)
            }
            if hasCodex {
                providerRow(codexLabel, codexPercent, UsageStyle.codex)
            }
            if hasAntigravity {
                Spacer(minLength: 4)
                header("ANTIGRAVITY wk", color: UsageStyle.gemini)
                Spacer(minLength: 2)
                metric("Claude+GPT", ag?.thirdParty?.weeklyUsed)
                metric("Gemini", ag?.gemini?.weeklyUsed)
            }
            if !hasAny {
                unavailable("AI USAGE", entry.error)
            }
            badges
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                if let limits = claude?.limits {
                    header("CLAUDE", color: UsageStyle.claude)
                    Spacer(minLength: 5)
                    metric("5-hour", limits.session?.percent, reset: limits.session?.resetsDate)
                    metric("Weekly", limits.weeklyAll?.percent, reset: limits.weeklyAll?.resetsDate)
                    metric(limits.weeklyScoped?.model ?? "Scoped",
                           limits.weeklyScoped?.percent,
                           reset: limits.weeklyScoped?.resetsDate)
                } else if hasClaude {
                    unavailable("CLAUDE", entry.payload?.claude?.error)
                } else if !hasAny {
                    unavailable("AI USAGE", entry.error)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 0) {
                if hasGrok {
                    providerRow(entry.payload?.grok?.windowLabel ?? "GROK", grokPercent, UsageStyle.label)
                    if let text = UsageStyle.resetText(entry.payload?.grok?.resetsDate) {
                        Text(text)
                            .font(.system(size: 9))
                            .foregroundStyle(UsageStyle.faint)
                    }
                    Spacer(minLength: 6)
                }
                if hasCodex {
                    providerRow(codexLabel, codexPercent, UsageStyle.codex)
                    if let text = UsageStyle.resetText(codex?.headline?.resetsDate,
                                                       expected: codex?.headline?.expectedResetsDate) {
                        Text(text)
                            .font(.system(size: 9))
                            .foregroundStyle(UsageStyle.faint)
                    }
                    Spacer(minLength: 7)
                }
                if hasAntigravity {
                    header("ANTIGRAVITY", color: UsageStyle.gemini)
                    Spacer(minLength: 3)
                    let cgWeekly = ag?.thirdParty?.weeklyUsed
                    metric("C+GPT wk", cgWeekly)
                    // n/a once the weekly is maxed: the 5-hour can't be spent, so its 0% is noise.
                    metric("C+GPT 5h", (cgWeekly ?? 0) >= 100 ? nil : ag?.thirdParty?.fiveHourUsed)
                    metric("Gemini wk", ag?.gemini?.weeklyUsed)
                    metric("Gemini 5h", ag?.gemini?.fiveHourUsed)
                    if let ag, ag.frozen {
                        Text("frozen \(ag.readingAge.map(UsageStyle.ageText) ?? "")")
                            .font(.system(size: 9))
                            .foregroundStyle(UsageStyle.color(for: 95))
                    } else if entry.payload?.antigravityStale == true {
                        Text("collector offline")
                            .font(.system(size: 9))
                            .foregroundStyle(UsageStyle.color(for: 75))
                    }
                }
                Spacer(minLength: 0)
                badges
            }
            .frame(maxWidth: 118, alignment: .leading)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let limits = claude?.limits {
                Text("CLAUDE").font(.system(size: 10, weight: .heavy))
                Text("wk \(UsageStyle.percentText(limits.weeklyAll?.percent))  ·  5h \(UsageStyle.percentText(limits.session?.percent))")
                    .font(.system(size: 13, weight: .semibold))
                if let scoped = limits.weeklyScoped, let model = scoped.model {
                    Text("\(model) \(UsageStyle.percentText(scoped.percent))")
                        .font(.system(size: 11))
                }
            } else if hasClaude {
                Text("CLAUDE").font(.system(size: 10, weight: .heavy))
                Text("no data").font(.system(size: 13, weight: .semibold))
            } else {
                // No Claude plan configured: fall back to whichever headline rows exist.
                Text("AI USAGE").font(.system(size: 10, weight: .heavy))
                let rows = headlineRows
                if rows.isEmpty {
                    Text("no data").font(.system(size: 13, weight: .semibold))
                } else {
                    Text(rows.prefix(2).map { "\($0.0) \(UsageStyle.percentText($0.1))" }
                             .joined(separator: "  ·  "))
                        .font(.system(size: 13, weight: .semibold))
                }
            }
        }
    }

    // MARK: Pieces

    /// A provider is "present" when the aggregator sent its key at all, error or not.
    /// Absent means not configured, and gets no row.
    private var hasClaude: Bool { entry.payload?.claude != nil }
    private var hasGrok: Bool { entry.payload?.grok != nil }
    private var hasCodex: Bool { entry.payload?.codex != nil }
    private var hasAntigravity: Bool { entry.payload?.antigravity != nil }
    private var hasAny: Bool { hasClaude || hasGrok || hasCodex || hasAntigravity }

    private var headlineRows: [(String, Double?)] {
        var rows: [(String, Double?)] = []
        if hasGrok { rows.append(("Grok", grokPercent)) }
        if hasCodex { rows.append(("Codex", codexPercent)) }
        if hasAntigravity { rows.append(("Gemini", ag?.gemini?.weeklyUsed)) }
        return rows
    }

    private var grokPercent: Double? {
        guard let grok = entry.payload?.grok, grok.ok == true else { return nil }
        return grok.percent
    }

    private var codex: CodexUsage? {
        guard let codex = entry.payload?.codex, codex.ok == true else { return nil }
        return codex
    }

    private var codexPercent: Double? { codex?.headline?.percent }

    private var codexLabel: String {
        codex?.headline?.label == "weekly" ? "CODEX wk" : "CODEX"
    }

    /// Every percentage in this widget is consumption. Antigravity's own panel shows
    /// the inverse (what is left), so its numbers are flipped once at collection time.
    private var ag: AntigravityUsage? {
        guard let ag = entry.payload?.antigravity, ag.ok == true else { return nil }
        return ag
    }

    private func header(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(color)
    }

    private func metric(_ label: String, _ percent: Double?, reset: Date? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(UsageStyle.label)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(UsageStyle.percentText(percent))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(UsageStyle.color(for: percent))
            }
            if let text = UsageStyle.resetText(reset) {
                Text(text)
                    .font(.system(size: 9))
                    .foregroundStyle(UsageStyle.faint)
            }
        }
        .padding(.bottom, reset == nil ? 3 : 4)
    }

    private func providerRow(_ label: String, _ percent: Double?, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(color)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(UsageStyle.percentText(percent))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(UsageStyle.color(for: percent))
        }
    }

    private func unavailable(_ title: String, _ error: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            header(title, color: UsageStyle.claude)
            Text(error ?? entry.error ?? "no data")
                .font(.system(size: 11))
                .foregroundStyle(UsageStyle.color(for: 100))
                .lineLimit(3)
        }
    }

    /// Anything at 100% is actively blocking work, so it earns space even here.
    /// A number on screen is not proof the number is current, so say when it is not.
    /// "offline" means this phone could not reach the aggregator and is showing its own
    /// cache; "stale" means it did reach it and the aggregator served its last good
    /// reading. Both sit on ONE line: stacked, they pushed the small layout past the
    /// widget's height and iOS clipped the top and bottom rows away (seen 2026-08-31,
    /// Grok at 100% with the phone off the tailnet, so both were showing at once).
    @ViewBuilder private var badges: some View {
        let hits = entry.payload?.atLimit ?? []
        let note = entry.payload?.fromCache == true ? "offline"
                 : entry.payload?.stale == true ? "stale" : nil
        if !hits.isEmpty || note != nil {
            HStack(spacing: 5) {
                if !hits.isEmpty {
                    Text(hits.count == 1 ? "AT LIMIT" : "\(hits.count) AT LIMIT")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(UsageStyle.color(for: 100))
                }
                if let note {
                    Text(note)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UsageStyle.color(for: 75))
                }
            }
        }
    }
}

enum UsageWidgetFamily {
    case small, medium, rectangular
}

struct UsageEntry {
    var date: Date
    var payload: UsagePayload?
    var error: String?
}
