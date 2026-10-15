import SwiftUI
import UIKit
import WidgetKit

/// povoX のウィジェット。povo へは通信せず、アプリが書いた残量(App Group)を表示するだけ。
struct Entry: TimelineEntry {
    let date: Date
    let snap: SharedSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snap: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snap: SharedSnapshot.load() ?? (context.isPreview ? .placeholder : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snap = SharedSnapshot.load()
        let now = Date()
        // 使い放題の残り時間などの表示を進めるため、15分ごとに描き直す(データはアプリが更新する)
        let entries = (0..<4).map { i in Entry(date: now.addingTimeInterval(Double(i) * 900), snap: snap) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

struct PovoXWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        WidgetContent(snap: entry.snap, family: family, now: entry.date)
            .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
            .widgetURL(URL(string: "povox://home"))
    }
}

struct PovoXWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PovoXRemaining", provider: Provider()) { entry in
            PovoXWidgetView(entry: entry)
        }
        .configurationDisplayName("povo の残量")
        .description("データ残量と、このペースであと何時間もつか。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct PovoXWidgetBundle: WidgetBundle {
    var body: some Widget {
        PovoXWidget()
    }
}
