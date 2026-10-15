import SwiftUI
import WidgetKit

/// ウィジェットの見た目(ウィジェット本体と、アプリの見本画面の両方で使う)。
struct WidgetContent: View {
    let snap: SharedSnapshot?
    let family: WidgetFamily
    var now = Date()

    private static let yellow = Color(red: 1.0, green: 0.961, blue: 0.0)

    private var fraction: Double {
        guard let s = snap, let left = s.leftKB else { return 0 }
        if s.unlimitedActive { return 1 }
        return min(1, left / max(s.planKB ?? left, left, 1))
    }

    private var valueText: (String, String) {
        guard let kb = snap?.leftKB else { return ("—", "") }
        let gb = kb / 1_048_576
        if gb >= 10 { return (String(format: "%.1f", gb), "GB") }
        if gb >= 1 { return (String(format: "%.2f", gb), "GB") }
        return (String(format: "%.0f", kb / 1024), "MB")
    }

    private var subText: String {
        guard let s = snap else { return "povoX を開いてください" }
        if s.unlimitedActive {
            if let u = s.unlimitedUntil { return "使い放題 \(Self.hm(u.timeIntervalSince(now) / 3600))" }
            return "使い放題中"
        }
        if let h = s.hoursLeft { return "あと\(Self.hm(h))" }
        return "残り"
    }

    static func hm(_ hours: Double) -> String {
        let m = max(0, Int((hours * 60).rounded()))
        if m < 60 { return "\(m)分" }
        if m < 24 * 60 { return "\(m / 60)時間" }
        return "\(m / 1440)日"
    }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        default: small
        }
    }

    private var ring: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * max(0.03, fraction))
                .stroke(Self.yellow, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(135))
            if snap?.unlimitedActive == true {
                Image(systemName: "infinity").font(.system(size: 22, weight: .bold))
            } else {
                VStack(spacing: -2) {
                    Text(valueText.0).font(.system(size: 22, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                    Text(valueText.1).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("povo").font(.caption.weight(.heavy))
                Spacer()
                if (snap?.pendingCount ?? 0) > 0 {
                    Image(systemName: "bell.badge.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            ring.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(subText).font(.caption2.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            ring.frame(width: 110, height: 110)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("povo のデータ").font(.caption.weight(.heavy))
                    if snap?.mock == true { Text("モック").font(.caption2).foregroundStyle(.purple) }
                }
                Text(snap?.unlimitedActive == true ? "使い放題中" : "\(valueText.0)\(valueText.1)")
                    .font(.title2.weight(.bold)).monospacedDigit()
                Text(subText).font(.caption).foregroundStyle(.secondary)
                if (snap?.pendingCount ?? 0) > 0 {
                    Label("確認待ちがあります", systemImage: "bell.badge.fill").font(.caption2).foregroundStyle(.orange)
                } else if let s = snap?.lastSummary {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if let u = snap?.updatedAt {
                    Text("更新 \(u, style: .time)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var circular: some View {
        Gauge(value: fraction) {
            Text("povo")
        } currentValueLabel: {
            if snap?.unlimitedActive == true {
                Image(systemName: "infinity")
            } else {
                Text(valueText.0).minimumScaleFactor(0.5)
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("povo").font(.caption2.weight(.heavy))
            Text(snap?.unlimitedActive == true ? "使い放題中" : "残り \(valueText.0)\(valueText.1)")
                .font(.headline).monospacedDigit()
            Text(subText).font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Text(snap?.unlimitedActive == true ? "povo 使い放題中" : "povo \(valueText.0)\(valueText.1)")
    }
}
