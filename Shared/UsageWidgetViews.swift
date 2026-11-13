import SwiftUI

/// The rendered widget content. Lives in Shared so the app can show a true-to-life
/// preview at each size without duplicating layout code.
///
/// Claude's weekly plan is always the big number, with the rest of Claude as bars under
/// it. Every other plan gets a name and a number in a fixed place, at the same size, and
/// only takes colour once it is worth a look.
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
    private var claudeRows: [Meter] { meters.dropFirst().filter { $0.tier == 1 } }
    private var others: [Meter] { meters.dropFirst().filter { $0.tier > 1 } }

    // MARK: Sizes

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hero {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(hero.name.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(hero.color)
                    Spacer(minLength: 4)
                    statusText(hero, size: 11)
                }
                // A 5-hour row, if the API reports one again, has to come out of the hero.
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(UsageStyle.percentText(hero.percent))
                        .font(.system(size: claudeRows.count > 1 ? 26 : 34, weight: .bold, design: .rounded))
                        .foregroundStyle(UsageStyle.color(for: hero.percent))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    warning(stacked: true)
                }
                PaceBar(percent: hero.percent, pace: hero.pace())
                    .frame(height: 6)
                    .padding(.bottom, 5)
                ForEach(claudeRows) { meterRow($0) }
                Spacer(minLength: 3)
                grid(others)
            } else {
                unavailable
            }
            Spacer(minLength: 3)
            resetsLine
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                if let hero {
                    Text(hero.name.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(hero.color)
                    Text(UsageStyle.percentText(hero.percent))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(UsageStyle.color(for: hero.percent))
                        .monospacedDigit()
                    statusText(hero, size: 11)
                    PaceBar(percent: hero.percent, pace: hero.pace())
                        .frame(height: 6)
                        .padding(.top, 4)
                } else {
                    unavailable
                }
                Spacer(minLength: 4)
                warning(stacked: false)
                resetsLine
            }
            .frame(width: 124, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(claudeRows + others) { m in
                    meterRow(m)
                    if m.tier <= 2, m.atLimit || m.runsOut() != nil, let s = m.status() {
                        Text(s)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(UsageStyle.color(for: m.atLimit ? 100 : 75))
                    }
                }
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
                Text(meters.dropFirst().filter { $0.tier <= 2 }.prefix(3)
                         .map { "\($0.name) \(UsageStyle.percentText($0.percent))" }
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

    /// "resets Sun", or in amber "out Sat 2 pm" when the limit empties first.
    private func statusText(_ m: Meter, size: CGFloat) -> some View {
        let early = m.runsOut() != nil
        return Text(m.status() ?? "")
            .font(.system(size: size, weight: early ? .semibold : .medium))
            .foregroundStyle(early ? UsageStyle.color(for: 75) : UsageStyle.faint)
            .lineLimit(1)
    }

    private func meterRow(_ m: Meter) -> some View {
        HStack(spacing: 6) {
            Text(m.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(m.color)
                .lineLimit(1)
                .frame(width: 46, alignment: .leading)
            PaceBar(percent: m.percent, pace: m.pace())
                .frame(height: 5)
            Text(UsageStyle.percentText(m.percent))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(m.tier > 1 ? UsageStyle.quietColor(for: m.percent) : UsageStyle.color(for: m.percent))
                .monospacedDigit()
                .fixedSize()
                .frame(minWidth: 36, alignment: .trailing)
        }
        .frame(height: 16)
    }

    /// Side plans, two to a row. Six fit; a seventh would need the medium widget.
    private func grid(_ ms: [Meter]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 2) {
            ForEach(ms.prefix(6)) { m in
                // Priority, or the stack offers the name half the spare width and it
                // truncates beside a three-digit number instead of shrinking.
                HStack(spacing: 0) {
                    Text(m.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(UsageStyle.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                    Spacer(minLength: 3)
                    Text(UsageStyle.percentText(m.percent))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(UsageStyle.quietColor(for: m.percent))
                        .fixedSize()
                }
            }
        }
    }

    private var resetsLine: some View {
        let resets = entry.payload?.bankedResets ?? []
        return HStack(spacing: 4) {
            if !resets.isEmpty {
                Text("Resets").foregroundStyle(UsageStyle.faint)
                Text(resets.map { "\($0.plan) \($0.count)" }.joined(separator: " · "))
                    .foregroundStyle(resets.contains { $0.urgent } ? UsageStyle.codex : UsageStyle.label)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    /// A number on screen is not proof the number is current, so say when it is not, and
    /// how old it is. "offline" means this phone could not reach the aggregator and is
    /// showing its own cache; "stale" means it did reach it and the aggregator served its
    /// last good reading.
    @ViewBuilder private func warning(stacked: Bool) -> some View {
        let state = entry.payload?.fromCache == true ? "offline"
                  : entry.payload?.stale == true ? "stale" : nil
        if let state {
            let age = entry.payload?.updatedDate
                .map { UsageStyle.ageText(Int(entry.date.timeIntervalSince($0))) + " old" }
            Group {
                if stacked {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(state)
                        if let age { Text(age) }
                    }
                } else {
                    Text([state, age].compactMap { $0 }.joined(separator: ", "))
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(UsageStyle.color(for: 75))
            .fixedSize()
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI USAGE")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(UsageStyle.claude)
            Text(entry.payload?.claude?.error ?? entry.error ?? "no data")
                .font(.system(size: 12))
                .foregroundStyle(UsageStyle.color(for: 100))
                .lineLimit(4)
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
