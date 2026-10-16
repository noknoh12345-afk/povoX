import Charts
import SwiftUI

/// 学習: 何を覚えたか・どれだけ当たるか・直した予定。
struct LearningView: View {
    @EnvironmentObject var store: AppStore
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                if let m = store.learned {
                    ForEach(Array(UsageLearner.lines(m).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout)
                    }
                    Text("最後に学習: \(Fmt.ago(ms: m.updatedMs))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("まだ学習していません。").foregroundStyle(.secondary)
                }
                Button {
                    Task {
                        busy = true
                        await store.relearn()
                        busy = false
                    }
                } label: {
                    HStack {
                        Label("今すぐ学習し直す", systemImage: "brain")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)
                .accessibilityIdentifier("learn.now")
            } header: {
                Text("覚えたこと")
            } footer: {
                Text("残量の記録・端末の通信量カウンタ・過去90日の予定・あなたの直しから、端末の中だけで学習します(外へは送りません)。外出の予定ごとの量は、件数が少ないうちは最初の目安に寄せます。「確かめ」は、学習に使っていない新しい予定で、見積もりがどれだけ外れたかです。")
            }

            if let m = store.learned, !m.weekdayP50.isEmpty || !m.dayOffP50.isEmpty {
                Section("いつもの1日(1時間ごとのモバイル通信・中央)") {
                    DayProfileChart(model: m)
                        .frame(height: 180)
                }
            }

            Section {
                let o = store.learned?.overrides ?? store.services.learning.overrides()
                if o.isEmpty {
                    Text("ホームの「今日のプラン」で、予定の「…」から「家だった」「外出だった」と直せます。同じ名前の予定(回の数字は無視)にも効きます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(o.keys.sorted(), id: \.self) { k in
                    HStack {
                        Text(k)
                        Spacer()
                        Text(o[k] == true ? "外出" : "家").foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("元に戻す", role: .destructive) { Task { await store.setOverride(title: k, outing: nil) } }
                    }
                }
            } header: {
                Text("直した予定")
            }
        }
        .navigationTitle("学習")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DayProfileChart: View {
    let model: LearnedModel

    private struct Bar: Identifiable {
        let id: String
        let hour: Int
        let mb: Double
        let kind: String
    }

    private var bars: [Bar] {
        var out: [Bar] = []
        for (i, v) in model.weekdayP50.enumerated() { out.append(Bar(id: "w\(i)", hour: i, mb: v, kind: "平日")) }
        for (i, v) in model.dayOffP50.enumerated() { out.append(Bar(id: "o\(i)", hour: i, mb: v, kind: "休日")) }
        return out
    }

    var body: some View {
        Chart(bars) { b in
            BarMark(x: .value("時", b.hour), y: .value("MB", b.mb))
                .foregroundStyle(by: .value("日", b.kind))
                .position(by: .value("日", b.kind))
        }
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                AxisGridLine()
                AxisValueLabel { if let h = v.as(Int.self) { Text("\(h)時") } }
            }
        }
        .chartForegroundStyleScale(["平日": Theme.warn, "休日": Color.blue])
    }
}
