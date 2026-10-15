import SwiftUI

/// シミュレーター: 仮の状態でルールと安全装置の判断を見る。povo には通信せず、記録も残さない。
struct SimulatorView: View {
    @EnvironmentObject var store: AppStore
    /// 指定すると、今のルールではなくこのルールで試す(レシピの下見などに使う)。
    var ruleOverride: String?
    var overrideTitle: String?
    @State private var leftGB = 0.3
    @State private var unlimited = false
    @State private var unlimitedHours = 2.0
    @State private var useForecast = true
    @State private var hoursLeft = 2.0
    @State private var battery = 15.0
    @State private var charging = false
    @State private var network = "cellular"
    @State private var trigger = "background"
    @State private var result: RunRecord?
    @State private var running = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("残量")
                        Spacer()
                        Text(Fmt.data(kb: leftGB * Fmt.kbPerGB)).monospacedDigit().fontWeight(.semibold)
                    }
                    Slider(value: $leftGB, in: 0...5, step: 0.05)
                        .accessibilityIdentifier("sim.left")
                }
                Toggle("使い放題中", isOn: $unlimited)
                if unlimited {
                    Stepper("使い放題の残り \(Fmt.duration(hours: unlimitedHours))", value: $unlimitedHours, in: 0.25...24, step: 0.25)
                }
                Toggle("減り方の予測あり", isOn: $useForecast)
                if useForecast {
                    Stepper("このペースで \(Fmt.duration(hours: hoursLeft))", value: $hoursLeft, in: 0.5...72, step: 0.5)
                }
            } header: {
                Text("回線の状態(仮)")
            }
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("電池")
                        Spacer()
                        Text("\(Int(battery))%").monospacedDigit().fontWeight(.semibold)
                    }
                    Slider(value: $battery, in: 0...100, step: 5)
                        .accessibilityIdentifier("sim.battery")
                }
                Toggle("充電中", isOn: $charging)
                Picker("ネットワーク", selection: $network) {
                    Text("モバイル通信").tag("cellular")
                    Text("Wi-Fi").tag("wifi")
                    Text("圏外").tag("none")
                }
                Picker("きっかけ", selection: $trigger) {
                    Text("裏で自動").tag("background")
                    Text("ショートカット").tag("shortcut")
                    Text("電池低下").tag("battery-low")
                    Text("手動").tag("manual")
                }
            } header: {
                Text("端末の状態(仮)")
            }
            Section {
                Button {
                    run()
                } label: {
                    if running { ProgressView().frame(maxWidth: .infinity) } else { Text("判定する").frame(maxWidth: .infinity) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("sim.run")
            } footer: {
                if store.catalog == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("トッピング一覧が未取得なので、購入の判定は「商品なし」になります。")
                        Button("一覧を読み込む(povo に1回通信)") { Task { await store.loadCatalog(force: false) } }
                    }
                } else {
                    Text("手持ちのコード・今月の予算・設定(確認/自動/試運転)は本物を使います。")
                }
            }
            if let r = result {
                Section("ルールの答えと安全装置の判断") {
                    RunResultView(run: r)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }
            if let t = overrideTitle {
                Section {
                    Label("「\(t)」を試しています(まだ今のルールには設定していません)", systemImage: "eye")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .textCase(nil)
        .navigationTitle("シミュレーター")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() {
        running = true
        let sim = SimInput(leftKb: leftGB * Fmt.kbPerGB, unlimited: unlimited, unlimitedHoursLeft: unlimited ? unlimitedHours : nil,
                           hoursLeft: useForecast ? hoursLeft : nil)
        let device = DeviceState(batteryLevel: Int(battery), charging: charging, full: false, lowPower: battery <= 20, network: network)
        Task {
            result = await store.simulate(sim, device: device, trigger: trigger, rule: ruleOverride)
            running = false
        }
    }
}
