import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if !store.onboardingDone {
                OnboardingView()
            } else if let st = store.status {
                if st.loggedIn {
                    MainTabs()
                } else {
                    LoginView()
                }
            } else {
                ProgressView()
            }
        }
        .task { await store.reload() }
        .alert(item: $store.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("閉じる")))
        }
        .sheet(item: $store.challenge) { page in
            ChallengeView(page: page)
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                ToastView(text: t)
                    .padding(.bottom, 64)
                    .onTapGesture { store.toast = nil }
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        if store.toast == t { store.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}

struct MainTabs: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView(selection: $store.tab) {
            HomeView()
                .tabItem { Label("ホーム", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(AppTab.home)
            ActivityView()
                .tabItem { Label("履歴", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.activity)
                .badge(store.pending.count)
            AutomationsView()
                .tabItem { Label("自動化", systemImage: "square.2.layers.3d.top.filled") }
                .tag(AppTab.rules)
            CodesView()
                .tabItem { Label("コード", systemImage: "ticket") }
                .tag(AppTab.codes)
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .background(KeyboardShortcuts())
    }
}

/// Mac(PlayCover など)やキーボード付き iPad 用。見えないボタンにショートカットキーを付ける。
/// ⌘1〜5 でタブ、⌘R で残量を更新、⌘Return で今すぐチェック。
private struct KeyboardShortcuts: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { i, tab in
                Button("") { store.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Button("") { Task { await store.refresh(force: true) } }
                .keyboardShortcut("r", modifiers: .command)
            Button("") { Task { _ = await store.runNow(dry: false) } }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// 停止中・待機中・モック・試運転の帯。
struct StatusBanners: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 8) {
            if let reason = store.status?.halted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("安全のため povo への通信を止めています", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.bold))
                    Text(reason).font(.caption)
                    Text("自動チェックも止まっています。原因を確かめてから再開してください。").font(.caption).foregroundStyle(.secondary)
                    Button("通信を再開") { Task { await store.unhalt() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.danger)
                        .accessibilityIdentifier("banner.unhalt")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if let until = store.status?.blockedUntilMs {
                banner("povo から待機を求められています(\(Fmt.when(ms: until)) まで)", "clock", .orange)
            }
            if store.status?.settings.dryRun == true {
                banner("試運転中: ルールの判断を記録するだけで、確認も実行もしません", "testtube.2", .purple)
            }
        }
    }

    private func banner(_ text: String, _ icon: String, _ tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
