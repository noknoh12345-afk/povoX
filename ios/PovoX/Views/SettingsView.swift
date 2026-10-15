import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmLogout = false
    @State private var confirmMock: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section("アカウント") {
                    LabeledContent("ログイン中", value: model.status?.identifier ?? "—")
                    Button("ログアウト(この iPhone から消す)", role: .destructive) { confirmLogout = true }
                }
                Section {
                    Toggle("モック(povo に通信しない練習用)", isOn: Binding(
                        get: { model.status?.mock ?? false },
                        set: { confirmMock = $0 }
                    ))
                } footer: {
                    Text("モックは作り物のデータで画面・スクリプト・安全装置を試せます(認証コード 000000)。モックと本番の記録・設定は別々に保存されます。")
                }
                Section {
                    if let st = model.status, st.halted != nil {
                        Button("通信を再開") { Task { await model.unhalt() } }
                    }
                    NavigationLink("povo への通信について") { AboutView() }
                }
                Section {
                    LabeledContent("バージョン", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                } footer: {
                    Text("非公式アプリです。KDDI・povo・Circles.life とは関係ありません。通信部分は公開ライブラリ povo-core(MIT)を使っています。")
                }
            }
            .navigationTitle("設定")
            .alert("ログアウトしますか?", isPresented: $confirmLogout) {
                Button("ログアウト", role: .destructive) { Task { await model.logout() } }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("この iPhone に保存したログイン情報を消します(povo 側には何も送りません)。")
            }
            .alert("切り替えますか?", isPresented: Binding(get: { confirmMock != nil }, set: { if !$0 { confirmMock = nil } })) {
                Button("切り替える") {
                    if let on = confirmMock { Task { await model.setMock(on) } }
                    confirmMock = nil
                }
                Button("やめる", role: .cancel) { confirmMock = nil }
            } message: {
                Text(confirmMock == true ? "モックにします。povo には通信しません。" : "本番にします。povo に通信します。")
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("弾かれないための作り(povo-web と同じ)") {
                Text("送る値は povo-android と同じ(X-App-Version 1.69.0-JP、User-Agent okhttp/4.12.0)。端末IDはログイン時に1回だけ作り、トークンと組で保存します。")
                Text("トークンの更新は期限切れ後だけ。povo への通信は常に1本ずつで、自動リトライはしません。")
                Text("403 や PIN 要求が返ったら、ここで「通信を再開」を押すまで、自動チェックも含めてすべて止めます。povo が待機時刻を返したら、その時刻まで送りません。")
                Text("認証コードの送信は60秒に1回まで、入れ直しは3回まで。")
            }
            Section("自動化で足したもの") {
                Text("povo への通信は5分間に20回まで。残量は30秒以内なら前回の値を使い、購入一覧は6時間使い回します。")
                Text("購入・コード送信は送る前に記録します。応答が失敗でも povo 側で処理された可能性があるため、自動では送り直しません。")
            }
        }
        .navigationTitle("通信について")
        .navigationBarTitleDisplayMode(.inline)
    }
}
