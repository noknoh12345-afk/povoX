import SwiftUI

struct AutomationView: View {
    @EnvironmentObject var model: AppModel
    @State private var settings: EngineSettings?
    @State private var confirmLive = false
    @State private var report: RunReport?
    @AppStorage("bgEnabled") private var bgEnabled = true
    @AppStorage("fgEnabled") private var fgEnabled = true
    @AppStorage("intervalMin") private var intervalMin = 30
    @AppStorage("notifyErrors") private var notifyErrors = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StatusBanners()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        Task { report = await model.runNow(test: true) }
                    } label: {
                        Label("試運転(買わずに流れだけ確かめる)", systemImage: "testtube.2")
                    }
                    Button {
                        Task { report = await model.runNow(test: false) }
                    } label: {
                        Label("今すぐ自動チェック", systemImage: "bolt.fill")
                    }
                    if let r = report {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.ok ? "結果: \(r.summary)" : "エラー: \(r.summary)")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(r.ok ? Color.primary : Theme.danger)
                            ForEach(Array(r.lines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("実行")
                }

                Section {
                    NavigationLink {
                        ScriptEditorView()
                    } label: {
                        Label("ルール(スクリプト)を編集", systemImage: "curlybraces")
                    }
                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("スクリプトの使い方", systemImage: "book")
                    }
                    NavigationLink {
                        LogsView()
                    } label: {
                        Label("ログ", systemImage: "list.bullet.rectangle")
                    }
                }

                if let s = settings {
                    Section {
                        Toggle("試運転(実際には購入・適用しない)", isOn: Binding(
                            get: { s.dryRun },
                            set: { on in
                                if on { update { $0.dryRun = true } } else { confirmLive = true }
                            }
                        ))
                        Stepper("月の上限: \(s.monthlyCapYen)円", value: binding(\.monthlyCapYen), in: 0...20000, step: 110)
                        Stepper("1日の回数: \(s.maxAutoOrdersPerDay)回", value: binding(\.maxAutoOrdersPerDay), in: 0...10)
                        Stepper("購入の間隔: \(s.autoOrderGapMin)分以上", value: binding(\.autoOrderGapMin), in: 0...1440, step: 10)
                        Toggle("コードの自動適用を許す", isOn: binding(\.autoCodes))
                        if let b = model.status?.budget {
                            Text("今月の自動購入 \(b.autoSpentYen)円(手動を含む合計 \(b.allSpentYen)円)・今日 \(b.autoToday)回")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("自動購入の安全装置")
                    } footer: {
                        Text("スクリプトがどう書かれていても、この上限を超える購入はしません。3Dセキュアが必要な商品は自動では買わず、通知だけします。")
                    }
                }

                Section {
                    Toggle("バックグラウンド更新", isOn: $bgEnabled)
                        .onChange(of: bgEnabled) { _ in Automation.scheduleBackgroundRefresh() }
                    Toggle("アプリを開いている間も自動チェック", isOn: $fgEnabled)
                        .onChange(of: fgEnabled) { _ in model.startForegroundTimer() }
                    Stepper("間隔: \(intervalMin)分", value: $intervalMin, in: 15...720, step: 15)
                        .onChange(of: intervalMin) { _ in
                            Automation.scheduleBackgroundRefresh()
                            model.startForegroundTimer()
                        }
                    Toggle("自動チェックのエラーを通知", isOn: $notifyErrors)
                    NavigationLink {
                        ShortcutsGuideView()
                    } label: {
                        Label("ショートカットで確実に動かす", systemImage: "square.stack.3d.up")
                    }
                } header: {
                    Text("きっかけ")
                } footer: {
                    Text("iOS はアプリを常に裏で動かせません。バックグラウンド更新は iOS が都合のよい時に動かすので、間隔は目安です(使い方によっては数時間空きます)。確実に動かしたいときは、ショートカットのオートメーション(バッテリー残量・充電器・時刻・Wi-Fi など)から「povoXの自動チェック」を呼んでください。")
                }
            }
            .navigationTitle("自動化")
            .task { await loadSettings() }
            .onReceive(model.$status) { st in
                if let st, settings == nil || settings != st.settings { settings = st.settings }
            }
            .alert("試運転を切りますか?", isPresented: $confirmLive) {
                Button("切る(実際に購入・適用する)", role: .destructive) { update { $0.dryRun = false } }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("スクリプトの条件を満たすと、上限の範囲で実際にトッピングを購入し、コードを適用します。試運転でログを確かめてからにしてください。")
            }
        }
    }

    private func loadSettings() async {
        await model.reloadLocal()
        settings = model.status?.settings
    }

    private func update(_ change: (inout EngineSettings) -> Void) {
        guard var s = settings else { return }
        change(&s)
        settings = s
        Task { await model.saveSettings(s) }
    }

    private func binding<T>(_ key: WritableKeyPath<EngineSettings, T>) -> Binding<T> {
        Binding(
            get: { settings![keyPath: key] },
            set: { v in update { $0[keyPath: key] = v } }
        )
    }
}

struct ScriptEditorView: View {
    @State private var text = Automation.script
    @State private var saved = true
    @State private var confirmReset = false

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.footnote, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 6)
            .onChange(of: text) { _ in saved = false }
            .navigationTitle("ルール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(saved ? "保存済み" : "保存") {
                        Automation.script = text
                        saved = true
                    }
                    .disabled(saved)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("最初のルールに戻す") { confirmReset = true }
                }
            }
            .alert("最初のルールに戻しますか?", isPresented: $confirmReset) {
                Button("戻す", role: .destructive) {
                    text = DefaultScript.text
                    Automation.script = text
                    saved = true
                }
                Button("やめる", role: .cancel) {}
            }
            .onDisappear {
                if !saved { Automation.script = text }
            }
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            Text(DefaultScript.help)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("使い方")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LogsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            if !model.ledger.isEmpty {
                Section("注文の記録") {
                    ForEach(model.ledger, id: \.self) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.auto ? "自動" : "手動") \(e.name ?? e.sku)\(e.priceYen.map { " \($0)円" } ?? "")")
                                .font(.callout)
                            Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) ・ \(ledgerStatus(e.status))\(e.message.map { " ・ \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("ログ") {
                ForEach(model.logs, id: \.self) { l in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(l.level))
                            .foregroundStyle(color(l.level))
                            .font(.caption)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.message).font(.caption)
                            Text(l.date.formatted(date: .abbreviated, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("ログ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("消去") { Task { await model.clearLogs() } }
            }
        }
        .task { await model.reloadLocal() }
        .refreshable { await model.reloadLocal() }
    }

    private func ledgerStatus(_ s: String) -> String {
        switch s {
        case "ok": return "注文完了"
        case "needs_3ds": return "3DS待ち"
        case "error": return "失敗(課金の可能性あり)"
        default: return "送信中/結果不明"
        }
    }

    private func icon(_ level: String) -> String {
        switch level {
        case "action": return "bolt.fill"
        case "warn": return "exclamationmark.triangle.fill"
        case "error": return "xmark.octagon.fill"
        default: return "circle.fill"
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "action": return .orange
        case "warn": return .yellow
        case "error": return Theme.danger
        default: return .secondary
        }
    }
}

struct ShortcutsGuideView: View {
    var body: some View {
        List {
            Section {
                Text("ショートカットの「オートメーション」に登録すると、条件を満たした瞬間に povoX の自動チェックが動きます(iOS 17 以降は「すぐに実行」で確認なし)。")
                    .font(.callout)
            }
            Section("手順") {
                Text("1. ショートカット App →「オートメーション」→「+」")
                Text("2. きっかけを選ぶ(下の例)")
                Text("3. 「すぐに実行」を選び、「次へ」")
                Text("4. アクションで「povoX」を検索し「povoXの自動チェック」を追加")
                Text("5. 必要なら「きっかけ」に文字を入れる(スクリプトの ctx.trigger に入ります)")
            }
            Section("おすすめのきっかけ") {
                Label("バッテリー残量が 20% を下回ったとき(trigger: battery-low)", systemImage: "battery.25")
                Label("充電器から外したとき(trigger: unplugged)", systemImage: "powerplug")
                Label("Wi-Fi から切断したとき(trigger: wifi-off)", systemImage: "wifi.slash")
                Label("毎日 7:00・12:00・18:00 など時刻(trigger: timer)", systemImage: "clock")
                Label("特定の App を開いたとき(地図・動画など)", systemImage: "app.badge")
            }
            Section("ほかのアクション") {
                Text("「povoXのデータ残量」: 残りGBを数値で返します。ショートカット側で条件分岐にも使えます。")
            }
        }
        .navigationTitle("ショートカット")
        .navigationBarTitleDisplayMode(.inline)
    }
}
