import SwiftUI

/// 初回だけ: 何をするアプリか・勝手には買わないこと・通知の許可。
struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }

    private let pages = [
        Page(icon: "gauge.with.dots.needle.67percent", title: "povo の残量を見守る",
             body: "残量を取りつづけて、減り方から「このペースであと何時間もつか」を予測します。ホーム画面とロック画面のウィジェットにも出せます。"),
        Page(icon: "calendar.badge.checkmark", title: "予定に合わせて、先回り",
             body: "カレンダーの予定から外出を見つけ、残量で足りるか・出かける前に何を入れておくと楽かを教えます。「残りが少ないとき」「予定の30分前」などのオートメーションも最初から入っています。"),
        Page(icon: "hand.raised", title: "勝手には買いません",
             body: "最初は「通知で確認」になっています。実行する前に通知で聞くので、ロック画面の「実行する」を押したときだけ行います。月の上限金額・1日の回数も決められます。"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 22) {
                        Spacer()
                        ZStack {
                            Circle().fill(Theme.yellow).frame(width: 132, height: 132)
                            Image(systemName: pages[i].icon)
                                .font(.system(size: 54, weight: .semibold))
                                .foregroundStyle(.black)
                        }
                        Text(pages[i].title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(pages[i].body)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        Spacer()
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 10) {
                if page < pages.count - 1 {
                    Button("次へ") { withAnimation { page += 1 } }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.next")
                } else {
                    Button("はじめる") { Task { await store.finishOnboarding() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("onboarding.start")
                    Text("通知とカレンダーの許可を求めます。予定は端末の中だけで使います。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.bg.ignoresSafeArea())
    }
}
