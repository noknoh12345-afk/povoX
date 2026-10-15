import SwiftUI
import UIKit

/// 通信まわりの設定・近道をまとめた画面。
///
/// できること・できないことは正直に出す。無料の Apple ID でサイドロードしたアプリは、
/// VPN／ネットワーク拡張の権限に署名できないため「ほかのアプリの通信を止める」ことはできない。
/// 代わりに iOS の設定への近道と、残量が少ないときに知らせるルールを案内する。
struct CommsSettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Button {
                    open(UIApplication.openSettingsURLString, fallback: nil)
                } label: {
                    row("povoX の設定を開く", "モバイル通信・位置情報・通知", "gearshape")
                }
                Button {
                    open("App-Prefs:root=MOBILE_DATA_SETTINGS_ID", fallback: "App-Prefs:")
                } label: {
                    row("モバイル通信の設定", "アプリごとのモバイル通信のオン・オフ", "antenna.radiowaves.left.and.right")
                }
                Button {
                    open("App-Prefs:root=WIFI", fallback: "App-Prefs:")
                } label: {
                    row("Wi-Fi の設定", "Wi-Fi につないでデータを節約", "wifi")
                }
            } header: {
                Text("iPhone の通信設定への近道")
            } footer: {
                Text("iOS の仕組み上、特定の設定画面が開けないことがあります。その場合は設定アプリが開くので、そこから進んでください。")
            }

            Section {
                Text("残量を節約したいときは、設定 → モバイル通信 →(アプリの一覧)で、使っていないアプリのモバイル通信をオフにできます。また「低データモード」をオンにすると、多くのアプリが裏での通信を控えます。")
                    .font(.callout)
                Button {
                    open("App-Prefs:root=MOBILE_DATA_SETTINGS_ID", fallback: "App-Prefs:")
                } label: {
                    Label("アプリごとのモバイル通信を設定", systemImage: "list.bullet")
                }
            } header: {
                Text("ほかのアプリの通信を抑える")
            } footer: {
                Text("アプリ自身が全アプリの通信を止めるには VPN／ネットワーク拡張の権限が必要ですが、無料の Apple ID で入れた povoX では署名できないため、この端末ではできません。上の手動の方法か、残量が少ないとき知らせるルール(レシピの「知らせるだけ」など)を使ってください。")
            }

            Section {
                Button {
                    openPovoOfficial()
                } label: {
                    row("povo 公式アプリ / サイトを開く", "国際ローミング・国際電話などの切り替え", "network")
                }
            } header: {
                Text("povo の通信設定(ローミングなど)")
            } footer: {
                Text("国際ローミングや国際電話のオン・オフは、料金に直結するため povoX からは自動で変えません。公式アプリ(または povo のサイト)で切り替えてください。")
            }

            if let note {
                Section {
                    Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .textCase(nil)
        .navigationTitle("通信の設定")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "arrow.up.forward.app").foregroundStyle(.tertiary)
        }
    }

    /// まず狙った設定画面を開き、だめなら設定アプリ(または povoX の設定)を開く。
    private func open(_ urlString: String, fallback: String?) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            guard !ok else { return }
            let next = fallback ?? UIApplication.openSettingsURLString
            if let u = URL(string: next), next != urlString {
                UIApplication.shared.open(u, options: [:]) { ok2 in
                    if !ok2, let s = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(s) }
                }
            } else if let s = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(s)
            }
            note = "この iOS ではその画面を直接開けなかったので、設定アプリを開きました。"
        }
    }

    /// povo 公式アプリ(URL スキーム)→ 無ければ povo のサイト。
    private func openPovoOfficial() {
        if let app = URL(string: "kddipovo://"), UIApplication.shared.canOpenURL(app) {
            UIApplication.shared.open(app)
        } else if let web = URL(string: "https://povo.jp/") {
            UIApplication.shared.open(web)
        }
    }
}
