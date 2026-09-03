import SwiftUI
import WidgetKit

extension UsageEntry: TimelineEntry {}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), payload: nil, error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let entry = await entry()
            // A failed fetch usually means the phone was off-network for a moment;
            // waiting the full 20 minutes to find out otherwise is the wrong trade.
            let wait = entry.payload == nil ? 5 * 60 : UsageConfig.refreshInterval
            let next = Date().addingTimeInterval(wait)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func entry() async -> UsageEntry {
        switch await UsageLoader.fetch() {
        case .success(let payload):
            return UsageEntry(date: Date(), payload: payload, error: nil)
        case .failure(let error):
            return UsageEntry(date: Date(), payload: nil, error: error.localizedDescription)
        }
    }
}

struct AIUsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var entry: UsageEntry

    var body: some View {
        UsageWidgetView(entry: entry, family: family)
            .containerBackground(UsageStyle.background, for: .widget)
    }

    private var family: UsageWidgetFamily {
        switch widgetFamily {
        case .systemSmall: .small
        case .accessoryRectangular: .rectangular
        default: .medium
        }
    }
}

struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIUsageWidget", provider: UsageProvider()) { entry in
            AIUsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Usage")
        .description("How much of each AI plan has been used.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct AIUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIUsageWidget()
    }
}
