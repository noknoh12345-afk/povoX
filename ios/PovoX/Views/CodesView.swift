import SwiftUI

struct CodesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var showManual = false
    @State private var applyTarget: CodeItem?
    @State private var confirmText = ""

    private var pending: [CodeItem] { model.codes.filter { $0.status == "pending" } }
    private var used: [CodeItem] { model.codes.filter { $0.status != "pending" }.sorted { ($0.sentMs ?? 0) > ($1.sentMs ?? 0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if pending.isEmpty {
                        Text("まだありません。右上の「+」でまとめて登録できます。").foregroundStyle(.secondary)
                    }
                    ForEach(pending) { c in
                        CodeRow(code: c)
                            .swipeActions {
                                Button(role: .destructive) { Task { await model.editCode("code_remove", id: c.id) } } label: { Label("削除", systemImage: "trash") }
                                Button { applyTarget = c } label: { Label("今使う", systemImage: "paperplane") }.tint(.blue)
                            }
                    }
                } header: {
                    Text("未使用(上から順に使います)")
                } footer: {
                    Text("スクリプトの povo.applyCode() / povo.applyCode(\"タグ\") がここから1件ずつ使います。送ったコードは二度と自動では送りません。データ使い放題の有効期間中は送りません。")
                }
                if !used.isEmpty {
                    Section("使用済み・結果") {
                        ForEach(used) { c in
                            CodeRow(code: c)
                                .swipeActions {
                                    Button(role: .destructive) { Task { await model.editCode("code_remove", id: c.id) } } label: { Label("削除", systemImage: "trash") }
                                    if c.status != "applied" {
                                        Button { Task { await model.editCode("code_reset", id: c.id) } } label: { Label("未使用に戻す", systemImage: "arrow.uturn.backward") }.tint(.orange)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("コード")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("コードを登録", systemImage: "plus") }
                        Button { showManual = true } label: { Label("1件だけ今すぐ入力", systemImage: "keyboard") }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) { AddCodesSheet() }
            .sheet(isPresented: $showManual) { ManualCodeSheet() }
            .alert("このコードを今使いますか?", isPresented: Binding(get: { applyTarget != nil }, set: { if !$0 { applyTarget = nil } })) {
                TextField("「利用する」と入力", text: $confirmText)
                Button("送信") {
                    if let c = applyTarget {
                        let word = confirmText
                        Task { await model.applyCode(id: c.id, confirm: word) }
                    }
                    confirmText = ""
                    applyTarget = nil
                }
                Button("やめる", role: .cancel) {
                    confirmText = ""
                    applyTarget = nil
                }
            } message: {
                Text("\(applyTarget?.masked ?? "")(\(applyTarget?.tag ?? ""))を povo に送ります。コードは1回しか使えないものがほとんどです。")
            }
            .refreshable { await model.reloadLocal() }
        }
    }
}

struct CodeRow: View {
    let code: CodeItem
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(reveal ? code.code : code.masked)
                    .font(.body.monospaced())
                    .onTapGesture { reveal.toggle() }
                if !code.tag.isEmpty {
                    Text(code.tag)
                        .font(.caption2.bold())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.yellow.opacity(0.6), in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer()
                Text(code.statusLabel).font(.caption).foregroundStyle(code.status == "applied" ? .green : (code.status == "pending" ? .secondary : .orange))
            }
            if !code.note.isEmpty { Text(code.note).font(.caption).foregroundStyle(.secondary) }
            if let r = code.result { Text(r).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

struct AddCodesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: CodesAddResult?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("1行に1件: コード タグ メモ")
                } footer: {
                    Text("例:\nABCD1234EFGH 1gb 7日間\nWXYZ5678 unlimited 24時間\nタグはスクリプトで povo.applyCode(\"1gb\") のように選ぶのに使います(省略可)。")
                }
                if let r = result {
                    Section {
                        Text("\(r.added)件を登録しました")
                        if !r.duplicates.isEmpty { Text("登録済みのため飛ばした: \(r.duplicates.joined(separator: ", "))").font(.caption) }
                        ForEach(r.invalid, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.danger) }
                    }
                }
            }
            .navigationTitle("コードを登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登録") {
                        Task {
                            result = await model.addCodes(text)
                            if let r = result, r.invalid.isEmpty { text = "" }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct ManualCodeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var confirm = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("コード", text: $code)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("確認のため「利用する」と入力", text: $confirm)
                } footer: {
                    Text("公式アプリと同じく、大文字にして前後の空白を除き、18文字以内で送ります。データ使い放題の有効期間中は入力しないでください。")
                }
                Section {
                    Button {
                        let c = code, w = confirm
                        Task {
                            await model.applyCode(raw: c, confirm: w)
                            dismiss()
                        }
                    } label: {
                        Text("送信").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(code.isEmpty || confirm != "利用する" || model.busy)
                }
            }
            .navigationTitle("コードを入力")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}
