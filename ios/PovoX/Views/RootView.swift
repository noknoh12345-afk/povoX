import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let st = model.status {
                if st.loggedIn {
                    MainTabs()
                } else {
                    LoginView()
                }
            } else {
                ProgressView("起動中…")
            }
        }
        .task { await model.reloadLocal() }
        .alert(item: $model.error) { e in
            Alert(title: Text(e.halt ? "通信を止めました" : "エラー"), message: Text(e.display), dismissButton: .default(Text("閉じる")))
        }
        .sheet(item: $model.challenge) { page in
            ChallengeView(page: page)
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                ToastView(text: t)
                    .padding(.bottom, 70)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                            if model.toast == t { model.toast = nil }
                        }
                    }
                    .onTapGesture { model.toast = nil }
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("ホーム", systemImage: "antenna.radiowaves.left.and.right") }
            AutomationView()
                .tabItem { Label("自動化", systemImage: "bolt.badge.clock") }
            CodesView()
                .tabItem { Label("コード", systemImage: "ticket") }
            ShopView()
                .tabItem { Label("トッピング", systemImage: "cart") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// 停止中・試運転中・モックの帯。
struct StatusBanners: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            if let reason = model.status?.halted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("安全のため povo への通信を止めています", systemImage: "hand.raised.fill")
                        .font(.subheadline.bold())
                    Text(reason).font(.caption)
                    Text("自動チェックも止まっています。原因を確かめてから再開してください。").font(.caption)
                    Button("通信を再開") { Task { await model.unhalt() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.danger)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            if let until = model.status?.blockedUntilMs {
                Label("povo から待機を求められています(\(Date(timeIntervalSince1970: Double(until) / 1000).formatted(date: .omitted, time: .shortened)) まで)", systemImage: "clock")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.status?.mock == true {
                Label("モック: povo には通信していません(作り物のデータ)", systemImage: "theatermasks")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.status?.settings.dryRun == true {
                Label("試運転中: 自動の購入・コード適用は実際には行いません", systemImage: "testtube.2")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.yellow.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
