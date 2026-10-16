import SwiftUI

/// オートメーションの色(FlowPalette の名前 → 色)。
enum FlowColor {
    static func color(_ name: String) -> Color {
        switch name {
        case "orange": return Color(red: 1.0, green: 0.58, blue: 0.0)
        case "red": return Color(red: 0.96, green: 0.27, blue: 0.27)
        case "pink": return Color(red: 0.98, green: 0.36, blue: 0.6)
        case "purple": return Color(red: 0.6, green: 0.4, blue: 0.95)
        case "blue": return Color(red: 0.2, green: 0.55, blue: 1.0)
        case "teal": return Color(red: 0.1, green: 0.72, blue: 0.75)
        case "green": return Color(red: 0.2, green: 0.75, blue: 0.4)
        case "gray": return Color(red: 0.55, green: 0.57, blue: 0.62)
        default: return Theme.yellow
        }
    }

    /// その色の上に置く文字の色。
    static func ink(_ name: String) -> Color {
        name == "yellow" ? .black : .white
    }
}

/// 角丸四角のアイコン(ショートカット App のアイコンのような)。
struct FlowIcon: View {
    let symbol: String
    let color: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(FlowColor.color(color).gradient)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(FlowColor.ink(color))
        }
        .frame(width: size, height: size)
    }
}

/// 部品の小さなアイコン(きっかけ・条件・アクションの行頭)。
struct PartIcon: View {
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// ホーム・自動化タブのショートカットのタイル。
struct FlowTile: View {
    let flow: Flow
    var busy = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            HStack(alignment: .top) {
                Image(systemName: flow.symbol)
                    .font(.system(size: compact ? 18 : 22, weight: .semibold))
                Spacer(minLength: 0)
                if busy {
                    ProgressView().tint(FlowColor.ink(flow.color))
                } else if flow.spends {
                    Image(systemName: "yensign.circle.fill").font(.caption).opacity(0.7)
                }
            }
            Spacer(minLength: 0)
            Text(flow.name)
                .font((compact ? Font.footnote : .subheadline).weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(FlowColor.ink(flow.color))
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, minHeight: compact ? 76 : 104, alignment: .leading)
        .background(FlowColor.color(flow.color).gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 曜日を選ぶ丸ボタンの列。nil は毎日。
struct WeekdayPicker: View {
    @Binding var days: [Int]?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { d in
                let on = (days ?? Array(0...6)).contains(d)
                Button {
                    var set = Set(days ?? Array(0...6))
                    if on { set.remove(d) } else { set.insert(d) }
                    if set.isEmpty { return }
                    days = set.count == 7 ? nil : set.sorted()
                } label: {
                    Text(FlowEngine.weekdayName(d))
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(on ? Color.black : Color.secondary)
                        .background(on ? AnyShapeStyle(Theme.yellow) : AnyShapeStyle(Theme.groove), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 選べる値の一覧から選ぶ(メニュー)。
struct ValuePicker<V: Hashable>: View {
    let title: String
    @Binding var value: V
    let options: [V]
    let label: (V) -> String

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(options, id: \.self) { o in
                Text(label(o)).tag(o)
            }
        }
        .pickerStyle(.menu)
    }
}

/// Optional の値を、無いときは既定の値として扱う。
func orDefault<T>(_ source: Binding<T?>, _ fallback: T) -> Binding<T> {
    Binding<T>(get: { source.wrappedValue ?? fallback }, set: { source.wrappedValue = $0 })
}

/// 最後に動いた時刻と結果(一覧の下に出す)。
struct FlowLastRun: View {
    let flow: Flow
    let memory: FlowMemory

    var body: some View {
        if let ms = memory.lastFiredMs[flow.id] {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                Text("\(Fmt.ago(ms: ms))")
                if let r = memory.lastResult[flow.id], !r.isEmpty {
                    Text("・\(r)").lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
