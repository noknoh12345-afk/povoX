import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmLogout = false
    @State private var confirmMock: Bool?
    @State private var confirmAuto: ActionMode?
    @State private var notifStatus: UNAuthorizationStatus?

    var body: some View {
        NavigationStack {
            Form {
                if let s = store.status?.settings {
                    Section {
                        modePicker("ルールによる購入", value: s.purchaseMode, id: "settings.purchaseMode") { m in
                            if m == .auto { confirmAuto = m } else { Task { await store.updateSettings { $0.purchaseMode = m } } }
                        }
                        modePicker("ルールによるコード適用", value: s.codeMode, id: "settings.codeMode") { m in
                            Task { await store.updateSettings { $0.codeMode = m } }
                        }
                        Toggle("試運転(記録だけ)", isOn: Binding(get: { s.dryRun }, set: { v in Task { await store.updateSettings { $0.dryRun = v } } }))
                        NavigationLink { SafetyView() } label: {
                            LabeledContent("上限・回数・間隔", value: "\(Fmt.yen(s.monthlyCapYen))/月")
                        }
                    } header: {
                        Text("動き方")
                    } footer: {
                        Text("「通知で確認」は、実行する前に通知で聞き、ロック画面の「実行する」を押したときだけ行います。")
                    }
                }

                Section {
                    NavigationLink { TriggersView() } label: {
                        Label("自動チェックのきっかけ", systemImage: "bolt.badge.clock")
                    }
                    HStack {
                        Label("通知", systemImage: "bell")
                        Spacer()
                        Text(notifText).foregroundStyle(.secondary)
                    }
                    if notifStatus == .denied {
                        Button("設定アプリで通知を許可") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    }
                    Toggle("実行したら通知", isOn: appBinding(\.notifyActions))
                    Toggle("エラーを通知", isOn: appBinding(\.notifyErrors))
                    HStack {
                        Label("ウィジェット", systemImage: "rectangle.3.group")
                        Spacer()
                        Text(WidgetBridge.available ? "使えます" : "使えません").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("アプリ")
                } footer: {
                    if !WidgetBridge.available {
                        Text("署名のしかたによっては App Group が使えず、ウィジェットに残量を渡せません。アプリの動作には影響しません。")
                    }
                }

                Section("アカウント") {
                    LabeledContent("ログイン中", value: store.status?.identifier ?? "—")
                    Toggle("モック(povo に通信しない)", isOn: Binding(get: { store.mock }, set: { confirmMock = $0 }))
                        .accessibilityIdentifier("settings.mock")
                    if store.status?.halted != nil {
                        Button("通信を再開") { Task { await store.unhalt() } }
                    }
                    Button("ログアウト(この iPhone から消す)", role: .destructive) { confirmLogout = true }
                }

                Section {
                    NavigationLink("povo への通信について") { AboutView() }
                    #if DEBUG
                    NavigationLink("ウィジェットの見た目(開発用)") { WidgetGalleryView() }
                    #endif
                    LabeledContent("バージョン", value: version)
                } footer: {
                    Text("非公式アプリです。KDDI・povo・Circles.life とは関係ありません。通信部分は公開ライブラリ povo-core(MIT)を使っています。")
                }
            }
            .textCase(nil)
            .navigationTitle("設定")
            .task { notifStatus = await store.services.notifications.authorizationStatus() }
            .alert("ログアウトしますか?", isPresented: $confirmLogout) {
                Button("ログアウト", role: .destructive) { Task { await store.logout() } }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("この iPhone に保存したログイン情報を消します(povo 側には何も送りません)。")
            }
            .alert("切り替えますか?", isPresented: Binding(get: { confirmMock != nil }, set: { if !$0 { confirmMock = nil } })) {
                Button("切り替える") {
                    if let on = confirmMock { Task { await store.setMock(on) } }
                    confirmMock = nil
                }
                Button("やめる", role: .cancel) { confirmMock = nil }
            } message: {
                Text(confirmMock == true ? "モックにします。povo には通信しません(記録・設定は本番と別です)。" : "本番にします。povo に通信します。")
            }
            .alert("自動で購入しますか?", isPresented: Binding(get: { confirmAuto != nil }, set: { if !$0 { confirmAuto = nil } })) {
                Button("自動にする", role: .destructive) {
                    Task { await store.updateSettings { $0.purchaseMode = .auto } }
                    confirmAuto = nil
                }
                Button("やめる", role: .cancel) { confirmAuto = nil }
            } message: {
                Text("ルールの条件を満たすと、確認なしで上限の範囲まで購入します。シミュレーターと試運転で動きを確かめてからにしてください。")
            }
        }
    }

    private var notifText: String {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral: return "許可済み"
        case .denied: return "許可されていません"
        case .notDetermined: return "未設定"
        default: return "—"
        }
    }

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func modePicker(_ title: String, value: ActionMode, id: String, set: @escaping (ActionMode) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            Text("しない").tag(ActionMode.off)
            Text("通知で確認").tag(ActionMode.confirm)
            Text("自動").tag(ActionMode.auto)
        }
        .accessibilityIdentifier(id)
    }

    private func appBinding(_ key: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        let settings = store.services.settings
        return Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0; store.objectWillChange.send() })
    }
}

/// 上限・回数・間隔・確認の有効時間・チェック間隔。
struct SafetyView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            if let s = store.status?.settings, let b = store.status?.budget {
                Section {
                    Stepper("月の上限 \(Fmt.yen(s.monthlyCapYen))", value: binding(\.monthlyCapYen, s), in: 0...20000, step: 110)
                    MeterBar(fraction: s.monthlyCapYen > 0 ? Double(b.ruleSpentYen) / Double(s.monthlyCapYen) : 0)
                    Text("今月のルールによる購入 \(Fmt.yen(b.ruleSpentYen))(手動は数えません)").font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("お金")
                }
                Section("回数と間隔") {
                    Stepper("1日 \(s.maxRuleOrdersPerDay)回まで", value: binding(\.maxRuleOrdersPerDay, s), in: 0...10)
                    Stepper("購入どうし \(s.orderGapMin)分あける", value: binding(\.orderGapMin, s), in: 0...1440, step: 10)
                    Stepper("確認は \(s.confirmTtlMin)分まで有効", value: binding(\.confirmTtlMin, s), in: 5...240, step: 5)
                }
                Section {
                    Stepper("最短 \(s.checkMinIntervalMin)分", value: binding(\.checkMinIntervalMin, s), in: 15...240, step: 15)
                    Stepper("最長 \(s.checkMaxIntervalMin)分", value: binding(\.checkMaxIntervalMin, s), in: 15...720, step: 15)
                } header: {
                    Text("自動チェックの間隔")
                } footer: {
                    Text("この範囲で、残量の減り方に合わせて間隔を変えます(なくなりそうなら短く、使い放題中は終わる頃に)。実際にバックグラウンドで起こされる時刻は iOS が決めます。")
                }
                Section {
                    Text("・3Dセキュアが要る商品はルールでは買いません\n・同じ商品は2分以内に重ねて注文しません\n・確認待ちがある間は、同じ種類を重ねて出しません\n・送ったコードは二度と自動では送りません\n・使い放題中はコードを送りません\n・povo から 403 などが返ったら全部止めます")
                        .font(.caption)
                } header: {
                    Text("いつもかかるもの")
                }
            }
        }
        .textCase(nil)
        .navigationTitle("安全装置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(_ key: WritableKeyPath<Settings, UInt32>, _ s: Settings) -> Binding<Int> {
        Binding(
            get: { Int(s[keyPath: key]) },
            set: { v in Task { await store.updateSettings { $0[keyPath: key] = UInt32(max(0, v)) } } }
        )
    }
}

/// 自動チェックのきっかけとショートカットの設定方法。
struct TriggersView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Form {
            Section {
                Toggle("バックグラウンド更新", isOn: Binding(
                    get: { store.services.settings.backgroundEnabled },
                    set: { v in
                        store.services.settings.backgroundEnabled = v
                        store.objectWillChange.send()
                        Task { await store.services.afterChange(summary: nil) }
                    }))
                Toggle("アプリを開いている間", isOn: Binding(
                    get: { store.services.settings.foregroundEnabled },
                    set: { v in
                        store.services.settings.foregroundEnabled = v
                        store.objectWillChange.send()
                        if v { store.startForeground() } else { store.stopForeground() }
                    }))
                if let next = BackgroundScheduler.nextScheduled, next > Date() {
                    LabeledContent("次の予約", value: Fmt.when(ms: Int64(next.timeIntervalSince1970 * 1000)))
                }
            } footer: {
                Text("iOS はアプリを常に動かせないので、バックグラウンド更新は iOS が都合のよいときに起こします(数時間空くこともあります)。確実に動かすには、下のショートカットのオートメーションを使ってください。設定アプリの「一般 → Appのバックグラウンド更新」で povoX をオンにしてください。")
            }
            Section("ショートカットで確実に動かす") {
                Text("ショートカット App →「オートメーション」→「+」→ きっかけを選ぶ →「すぐに実行」→ アクションに「povoXの自動チェック」を追加。「きっかけ」に文字を入れると ctx.trigger に入ります。")
                    .font(.callout)
                Label("バッテリー残量が 20% を下回ったとき(battery-low)", systemImage: "battery.25")
                Label("充電器から外したとき(unplugged)", systemImage: "powerplug")
                Label("Wi-Fi から切断したとき(wifi-off)", systemImage: "wifi.slash")
                Label("毎日 7:00・12:00・18:00(timer)", systemImage: "clock")
                Label("地図・動画の App を開いたとき(app-open)", systemImage: "app.badge")
            }
            Section("ほかのアクション") {
                Text("「povoXのデータ残量」: 残り GB を数値で返します。\n「povoXの購入のしかたを変える」: 旅行中だけ「自動」にする、などに。")
                    .font(.callout)
            }
        }
        .textCase(nil)
        .navigationTitle("きっかけ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                Text("送る値は povo-android と同じ(X-App-Version 1.69.0-JP、User-Agent okhttp/4.12.0)。端末IDはログイン時に1回だけ作り、トークンと組で保存します。")
                Text("トークンの更新は期限切れ後だけ。povo への通信は常に1本ずつで、自動リトライはしません。")
                Text("403 や PIN 要求が返ったら、「通信を再開」を押すまで自動チェックも含めてすべて止めます。povo が待機時刻を返したら、その時刻まで送りません。")
                Text("認証コードの送信は60秒に1回まで、入れ直しは3回まで。")
            } header: {
                Text("弾かれないための作り(povo-web と同じ)").textCase(nil)
            }
            Section("自動化の作り") {
                Text("ルールは「何をするか」を返すだけで、povo へ送るのはアプリの中のエンジン(Rust)だけです。購入・コードは送る前に記録し、失敗しても自動では送り直しません。")
                Text("povo への通信は5分間に20回まで。残量は30秒以内なら前回の値、購入一覧は6時間使い回します。")
            }
        }
        .font(.callout)
        .navigationTitle("通信について")
        .navigationBarTitleDisplayMode(.inline)
    }
}
