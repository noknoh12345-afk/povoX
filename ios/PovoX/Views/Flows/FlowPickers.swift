import SwiftUI

/// 部品を選んだときの既定の値。
enum FlowDefaults {
    static func trigger(_ k: FlowTriggerKind) -> FlowTrigger {
        switch k {
        case .dataBelow: return .dataBelow(0.1)
        case .hoursLeftBelow: return .hoursLeftBelow(3)
        case .unlimitedEnding: return .unlimitedEnding(10)
        case .batteryBelow: return .batteryBelow(20)
        case .timeOfDay: return .time(7, 30)
        case .calendarEvent: return .calendar(lead: 30, outingOnly: true)
        case .usedTodayAbove: return .usedToday(1000)
        case .shortcut: return .shortcut("出発")
        case .once: return .once(Date().addingTimeInterval(3600))
        default: return FlowTrigger(k)
        }
    }

    static func condition(_ k: FlowConditionKind) -> FlowCondition {
        switch k {
        case .dataBelow: return .dataBelow(0.5)
        case .dataAbove: return .dataAbove(1)
        case .hoursLeftBelow: return .hoursLeftBelow(6)
        case .batteryBelow: return .batteryBelow(20)
        case .timeBetween: return .between(7, 23)
        case .weekdays: return .weekdays([1, 2, 3, 4, 5])
        case .outingWithin: return .outingWithin(3)
        case .usedTodayAbove: return .usedTodayAbove(1000)
        default: return FlowCondition(k)
        }
    }

    static func action(_ k: FlowActionKind) -> FlowAction {
        switch k {
        case .buyUnlimited: return .unlimited(24)
        case .notify: return .notify("povoX", "残り {残量}")
        case .dayBrief: return .brief("auto")
        case .setPurchaseMode: return .purchaseMode("confirm")
        case .setCodeMode: return .codeMode("confirm")
        case .log: return .log("")
        case .setFlowEnabled:
            var a = FlowAction(.setFlowEnabled)
            a.on = true
            return a
        default: return FlowAction(k)
        }
    }

    /// きっかけの説明(選ぶ画面の小さな字)。
    static func triggerHint(_ k: FlowTriggerKind) -> String {
        switch k {
        case .manual: return "ホームのボタン・Siri・ショートカット App から"
        case .calendarEvent: return "カレンダーの予定の少し前。外出の予定だけにもできます"
        case .timeOfDay: return "毎朝・毎晩など。時刻に通知でお知らせします"
        case .dataBelow: return "残量が決めた量を下回った瞬間"
        case .unlimitedEnding: return "使い放題の残り時間が少なくなったとき"
        case .hoursLeftBelow: return "減り方から見て、もうすぐなくなりそうなとき"
        case .unlimitedEnded: return "使い放題の期間が終わったとき"
        case .usedTodayAbove: return "今日の使用量が多いとき"
        case .anyCheck: return "povoX が残量を確かめるたび(間隔をあけて)"
        case .leftWifi: return "家などの Wi-Fi から離れたとき(次の自動チェックで気づきます)"
        case .joinedWifi: return "Wi-Fi につながったとき"
        case .leave: return "位置情報(常に許可)で、移動したとき"
        case .arrive: return "位置情報(常に許可)で、どこかに着いたとき"
        case .batteryBelow: return "電池が少なくなったとき"
        case .unplugged: return "充電器を外したとき(出かける合図に)"
        case .shortcut: return "ショートカット App のオートメーションから名前で呼ぶ"
        case .once: return "決めた日時に1回だけ"
        }
    }
}

struct TriggerPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (FlowTrigger) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(FlowText.triggerGroups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { k in
                            Button {
                                onPick(FlowDefaults.trigger(k))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    PartIcon(symbol: FlowText.triggerSymbol(k), tint: .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(FlowText.triggerTitle(k)).foregroundStyle(.primary)
                                        Text(FlowDefaults.triggerHint(k)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("pick.trigger.\(k.rawValue)")
                        }
                    }
                }
            }
            .navigationTitle("いつ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

struct ConditionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (FlowCondition) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(FlowText.conditionGroups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { k in
                            Button {
                                onPick(FlowDefaults.condition(k))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    PartIcon(symbol: FlowText.conditionSymbol(k), tint: .blue)
                                    Text(FlowText.conditionTitle(k)).foregroundStyle(.primary)
                                }
                            }
                            .accessibilityIdentifier("pick.condition.\(k.rawValue)")
                        }
                    }
                }
            }
            .navigationTitle("もし")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

struct ActionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (FlowAction) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(FlowText.actionGroups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.self) { k in
                            Button {
                                onPick(FlowDefaults.action(k))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    PartIcon(symbol: FlowText.actionSymbol(k), tint: Theme.ok)
                                    Text(FlowText.actionTitle(k)).foregroundStyle(.primary)
                                }
                            }
                            .accessibilityIdentifier("pick.action.\(k.rawValue)")
                        }
                    }
                }
            }
            .navigationTitle("すること")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

/// アイコンと色を選ぶ。
struct FlowIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var symbol: String
    @Binding var color: String

    static let symbols = [
        "bolt.fill", "infinity", "sun.max.fill", "moon.stars.fill", "figure.walk", "figure.walk.departure", "airplane", "tram.fill",
        "car.fill", "bicycle", "house.fill", "building.2.fill", "briefcase.fill", "book.fill", "music.mic", "film",
        "gamecontroller.fill", "fork.knife", "cup.and.saucer.fill", "bag.fill", "cart.fill", "ticket.fill", "gift.fill", "bell.fill",
        "calendar", "calendar.badge.clock", "clock.fill", "timer", "hourglass", "wifi", "wifi.slash", "antenna.radiowaves.left.and.right",
        "battery.25percent", "powerplug", "wand.and.stars", "sparkles", "star.fill", "heart.fill", "hand.raised.fill", "shield.lefthalf.filled",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    FlowIcon(symbol: symbol, color: color, size: 84)
                        .padding(.top, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 9), spacing: 10) {
                        ForEach(FlowPalette.names, id: \.self) { c in
                            Circle()
                                .fill(FlowColor.color(c))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(Color.primary, lineWidth: c == color ? 3 : 0).padding(-4))
                                .onTapGesture { color = c }
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                        ForEach(FlowIconPicker.symbols, id: \.self) { s in
                            Image(systemName: s)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 46, height: 46)
                                .foregroundStyle(s == symbol ? FlowColor.ink(color) : .primary)
                                .background(s == symbol ? AnyShapeStyle(FlowColor.color(color)) : AnyShapeStyle(Theme.groove),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onTapGesture { symbol = s }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("アイコン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
        }
    }
}
