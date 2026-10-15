import SwiftUI

struct RuleEditorView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?
    @State private var loaded = false

    private var changed: Bool { text != store.rule }

    var body: some View {
        VStack(spacing: 0) {
            if let p = problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.danger.opacity(0.1))
                    .accessibilityIdentifier("editor.problem")
            }
            TextEditor(text: $text)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .background(Theme.card)
                .accessibilityIdentifier("editor.text")
        }
        .navigationTitle("ルールを編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .fontWeight(.semibold)
                    .disabled(!changed)
                    .accessibilityIdentifier("editor.save")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("確かめる") { problem = RuleEngine.check(rule: text, prelude: RuleLibrary.prelude(), settings: store.services.settings) ?? "問題は見つかりませんでした" }
                Spacer()
                Button("元に戻す") {
                    text = store.rule
                    problem = nil
                }
                .disabled(!changed)
            }
        }
        .onAppear {
            if !loaded {
                text = store.rule
                loaded = true
            }
        }
    }

    private func save() {
        if let err = store.saveRule(text, templateID: nil) {
            problem = err
        } else {
            problem = nil
            store.toast = "ルールを保存しました"
            dismiss()
        }
    }
}

struct TemplatePickerView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var pick: RuleTemplate?

    var body: some View {
        List {
            Section {
                ForEach(RuleLibrary.templates()) { t in
                    Button {
                        pick = t
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: store.ruleTemplateID == t.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.ruleTemplateID == t.id ? Theme.ok : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t.title).font(.headline).foregroundStyle(.primary)
                                Text(t.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("template.\(t.id)")
                }
            } footer: {
                Text("選んだあと「編集」で数字や条件を変えられます。")
            }
        }
        .navigationTitle("テンプレート")
        .navigationBarTitleDisplayMode(.inline)
        .alert("このテンプレートにしますか?", isPresented: Binding(get: { pick != nil }, set: { if !$0 { pick = nil } })) {
            Button("使う") {
                if let t = pick {
                    if let err = store.saveRule(t.source, templateID: t.id) {
                        store.alert = AlertMessage(title: "保存できませんでした", message: err)
                    } else {
                        store.toast = "「\(t.title)」にしました"
                        dismiss()
                    }
                }
                pick = nil
            }
            Button("やめる", role: .cancel) { pick = nil }
        } message: {
            Text("今のルールは置き換わります。")
        }
    }
}

struct RuleHelpView: View {
    var body: some View {
        ScrollView {
            Text(RuleHelp.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Theme.bg)
        .navigationTitle("ルールの書き方")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum RuleHelp {
    static let text = #"""
    ルールは function decide(ctx) で「何をするか」を返します。
    povo へ送るのは povoX の安全装置で、ルールからは送れません。

    ■ 返せるもの
    skip("理由")                 何もしない
    notify("題名", "本文")         通知を出す
    applyCode()                  手持ちのコードを1件使う
    applyCode("1gb")             タグで選ぶ / applyCode({ id })
    buy(商品)                    トッピングを買う(商品が null なら何もしない)
    firstOf(a, b, c)             上から順に、最初にできたものだけ
    all(a, b)                    全部(購入・コードは1回で1つまで)

    ■ ctx
    ctx.data.leftGB / leftMB     残り(読めなければ null)
    ctx.data.unlimited           { active, untilMs, hoursLeft }
    ctx.data.toppings            ご利用中のトッピング
    ctx.forecast                 { hoursLeft(このペースで0になるまで), mbPerHour, usedTodayMB }
    ctx.codes                    未使用のコード [{ id, tag, note, masked }]
    ctx.budget                   { capYen, spentYen, remainingYen, todayCount, maxPerDay }
    ctx.battery                  { level(0〜100), charging, lowPower }
    ctx.network                  "wifi" / "cellular" / "none"
    ctx.now                      { hour, minute, weekday(0=日), date }
    ctx.trigger                  "background" / "shortcut" / "foreground" / "manual" / 任意
    ctx.mode                     "live" / "dry" / "simulate"
    ctx.catalog()                購入できる商品 [{ sku, name, price, gb, hours, unlimited, yenPerGB, requires3ds }]
    ctx.lastRun                  前回 { ms, summary }

    ■ 道具
    cheapest(一覧, p => 条件)     条件に合う最安(3DSが要るものは除く)
    log(...)                     実行の記録に残す
    state.get(キー, 既定) / state.set(キー, 値)   実行をまたいで値を残す

    ■ 例: 電池が少ないときは1時間の使い放題
    function decide(ctx) {
      const d = ctx.data;
      if (d.unlimited.active || d.leftGB >= 0.5) return skip("十分");
      const short = ctx.battery.level <= 20 && !ctx.battery.charging;
      return firstOf(
        applyCode(),
        buy(cheapest(ctx.catalog(), p => p.unlimited && p.hours === (short ? 1 : 24))),
        notify("残りわずか", `${d.leftMB.toFixed(0)}MB`)
      );
    }

    ■ 必ずかかる安全装置
    ・購入/コードは設定の「しない・通知で確認・自動」に従う(既定は通知で確認)
    ・月の上限金額・1日の回数・前回からの間隔・3DSが要る商品は買わない
    ・同じ商品は2分以内に重ねない・確認待ちがある間は重ねて出さない
    ・コードは送ったら二度と自動では送らない・15秒に1回まで・使い放題中は送らない
    ・povo への通信は5分間に20回まで。403 などが返ったら全部止まる
    ・ルールの実行は3秒まで
    """#
}
