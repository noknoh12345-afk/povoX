#if DEBUG
import SwiftUI
import WidgetKit

/// 開発用: ウィジェットの見た目を、今のデータと見本データで並べる(UI テストのスクリーンショット用)。
struct WidgetGalleryView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var scheme

    private var current: SharedSnapshot? {
        guard let s = store.snapshot else { return nil }
        return SharedSnapshot(updatedAt: Fmt.date(ms: s.fetchedMs), leftKB: s.leftKb, planKB: s.planKb,
                              unlimitedActive: s.unlimited.active == true, unlimitedUntil: s.unlimited.untilMs.map { Fmt.date(ms: $0) },
                              hoursLeft: store.insights?.hoursLeft, pendingCount: store.pending.count, mock: store.mock,
                              lastSummary: store.runs.first?.summary)
    }

    private var samples: [(String, SharedSnapshot?)] {
        var unl = SharedSnapshot.placeholder
        unl.unlimitedActive = true
        unl.unlimitedUntil = Date().addingTimeInterval(5400)
        var low = SharedSnapshot.placeholder
        low.leftKB = 180 * 1024
        low.hoursLeft = 1.2
        low.pendingCount = 1
        return [("今のデータ", current), ("使い放題中", unl), ("残りわずか・確認待ち", low), ("データなし", nil)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(samples.indices, id: \.self) { i in
                    let title = samples[i].0
                    let snap = samples[i].1
                    Text(title).font(.headline)
                    HStack(spacing: 14) {
                        tile(snap, .systemSmall).frame(width: 158, height: 158)
                        VStack(spacing: 10) {
                            tile(snap, .accessoryCircular).frame(width: 64, height: 64)
                            tile(snap, .accessoryRectangular).frame(width: 160, height: 60)
                        }
                    }
                    tile(snap, .systemMedium).frame(height: 158)
                }
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("ウィジェット")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tile(_ snap: SharedSnapshot?, _ family: WidgetFamily) -> some View {
        WidgetContent(snap: snap, family: family)
            .padding(family == .accessoryCircular || family == .accessoryRectangular ? 4 : 14)
            .background(family == .accessoryCircular || family == .accessoryRectangular ? Color.black.opacity(0.85) : Theme.card,
                        in: RoundedRectangle(cornerRadius: family == .accessoryCircular ? 32 : 22, style: .continuous))
            .environment(\.colorScheme, family == .accessoryCircular || family == .accessoryRectangular ? .dark : scheme)
    }
}
#endif
