import SwiftUI

/// The rendered widget content. Lives in Shared so the app can show a true-to-life
/// preview at each size without duplicating layout code.
///
/// Claude's weekly plan is always the big number. The limits Campbell watches closely
/// (Fable, Argon) get bars of their own; everything else shares a compact line, so a
/// side plan like Muse never takes the space however full it is.
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

    private var meters: [Meter] { entry.payload?.meters ?? [] }
    private var hero: Meter? { meters.first }
    private var watched: [Meter] { meters.dropFirst().filter { $0.tier <= 2 } }
    private var others: [Meter] { meters.dropFirst().filter { $0.tier > 2 } }

    // MARK: Sizes

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hero {
                heroBlock(hero, size: 30)
                Spacer(minLength: 6)
                ForEach(watched) { meterRow($0) }
                compactLine(others)
                    .padding(.top, 2)
            } else {
                unavailable
            }
            Spacer(minLength: 0)
            badges
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                if let hero {
                    heroBlock(hero, size: 38)
                } else {
                    unavailable
                }
                Spacer(minLength: 4)
                extras
                badges
            }
            .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(watched) { m in
                    VStack(alignment: .leading, spacing: 0) {
                        meterRow(m)
                        if m.atLimit || m.runsOut() != nil, let s = m.status() {
                            Text(s)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(UsageStyle.color(for: m.atLimit ? 100 : 75))
                        }
                    }
                }
                ForEach(others) { meterRow($0) }
                Spacer(minLength: 0)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let hero {
                Text(hero.name.uppercased()).font(.system(size: 10, weight: .heavy))
                Text(UsageStyle.percentText(hero.percent) + (hero.status().map { "  ·  \($0)" } ?? ""))
                    .font(.system(size: 13, weight: .semibold))
                Text(watched.prefix(3).map { "\($0.name) \(UsageStyle.percentText($0.percent))" }
                         .joined(separator: "  "))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("AI USAGE").font(.system(size: 10, weight: .heavy))
                Text("no data").font(.system(size: 13, weight: .semibold))
            }
        }
    }

    // MARK: Pieces

    private func heroBlock(_ m: Meter, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(m.name.uppercased())
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(m.color)
                .lineLimit(1)
            Text(UsageStyle.percentText(m.percent))
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(UsageStyle.color(for: m.percent))
                .monospacedDigit()
            if let s = m.status() {
                Text(s)
                    .font(.system(size: 10, weight: m.runsOut() == nil ? .regular : .semibold))
                    .foregroundStyle(m.runsOut() == nil ? UsageStyle.faint : UsageStyle.color(for: 75))
                    .lineLimit(1)
            }
            PaceBar(percent: m.percent, pace: m.pace())
                .frame(height: 5)
                .padding(.top, 3)
        }
    }

    private func meterRow(_ m: Meter) -> some View {
        HStack(spacing: 5) {
            Text(m.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(m.color)
                .lineLimit(1)
                .frame(width: 44, alignment: .leading)
            PaceBar(percent: m.percent, pace: m.pace())
                .frame(height: 4)
            Text(UsageStyle.percentText(m.percent))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(UsageStyle.color(for: m.percent))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .frame(height: 15)
    }

    /// Side plans as text. A percentage only takes colour once it is worth a look.
    private func compactLine(_ ms: [Meter]) -> some View {
        var a = AttributedString()
        for (i, m) in ms.enumerated() {
            var name = AttributedString((i == 0 ? "" : " · ") + m.name + " ")
            name.foregroundColor = UsageStyle.faint
            var pct = AttributedString(UsageStyle.percentText(m.percent))
            pct.foregroundColor = (m.percent ?? 0) >= 70 ? UsageStyle.color(for: m.percent) : UsageStyle.faint
            a += name + pct
        }
        return Text(a)
            .font(.system(size: 9))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    /// The banked extras that change what to do next: a Claude reset or a Codex credit.
    @ViewBuilder private var extras: some View {
        if let n = entry.payload?.claude?.limitReset?.left, n > 0 {
            Text("Claude: \(n) reset banked")
                .font(.system(size: 9))
                .foregroundStyle(UsageStyle.faint)
        }
        if let codex = entry.payload?.codex, codex.ok == true {
            let paid = codex.credits.map { $0.unlimited == true || ($0.balance ?? 0) > 0 } ?? false
            let n = (codex.resetCredits ?? 0) + (paid ? 1 : 0)
            if n > 0 {
                let redeem = codex.resetCreditAdvice == "redeem"
                Text("Codex: \(n) reset/credit \(redeem ? "· use" : "banked")")
                    .font(.system(size: 9, weight: redeem ? .bold : .regular))
                    .foregroundStyle(redeem ? UsageStyle.codex : UsageStyle.faint)
            }
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI USAGE")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(UsageStyle.claude)
            Text(entry.payload?.claude?.error ?? entry.error ?? "no data")
                .font(.system(size: 11))
                .foregroundStyle(UsageStyle.color(for: 100))
                .lineLimit(3)
        }
    }

    /// A number on screen is not proof the number is current, so say when it is not.
    /// "offline" means this phone could not reach the aggregator and is showing its own
    /// cache; "stale" means it did reach it and the aggregator served its last good
    /// reading. Full limits need no badge: every limit is on screen with its own colour.
    @ViewBuilder private var badges: some View {
        let note = entry.payload?.fromCache == true ? "offline"
                 : entry.payload?.stale == true ? "stale" : nil
        if let note {
            Text(note)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(UsageStyle.color(for: 75))
        }
    }
}

/// A usage bar with a tick where even spending would sit now. Fill past the tick means
/// the limit is being spent faster than the window is passing.
struct PaceBar: View {
    var percent: Double?
    var pace: Double?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(UsageStyle.color(for: percent))
                    .frame(width: w * min(max((percent ?? 0) / 100, 0), 1))
                if let pace {
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 1.5, height: g.size.height + 3)
                        .offset(x: w * min(pace / 100, 1) - 0.75)
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
