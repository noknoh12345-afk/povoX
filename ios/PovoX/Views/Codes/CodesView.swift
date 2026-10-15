import SwiftUI
import VisionKit

struct CodesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showAdd = false
    @State private var showManual = false
    @State private var applyTarget: CodeEntry?
    @State private var confirmText = ""
    @State private var editTarget: CodeEntry?

    private var pending: [CodeEntry] { store.codes.filter { $0.status == .pending } }
    private var used: [CodeEntry] { store.codes.filter { $0.status != .pending }.sorted { ($0.sentMs ?? 0) > ($1.sentMs ?? 0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if pending.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("手持ちのコードを登録しておくと、残りが少なくなったときにルールが1件ずつ使います。")
                                .font(.callout).foregroundStyle(.secondary)
                            Button { showAdd = true } label: { Label("コードを登録", systemImage: "plus") }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(pending) { c in
                        CodeRow(code: c)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await store.removeCode(c.id) } } label: { Label("削除", systemImage: "trash") }
                                Button { editTarget = c } label: { Label("編集", systemImage: "pencil") }.tint(.gray)
                            }
                            .swipeActions(edge: .leading) {
                                Button { applyTarget = c } label: { Label("今使う", systemImage: "paperplane") }.tint(.blue)
                            }
                            .contextMenu {
                                Button { applyTarget = c } label: { Label("今使う", systemImage: "paperplane") }
                                Button { editTarget = c } label: { Label("タグ・メモを編集", systemImage: "pencil") }
                                Button(role: .destructive) { Task { await store.removeCode(c.id) } } label: { Label("削除", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text("未使用(上から順に使います)")
                } footer: {
                    Text("送ったコードは二度と自動では送りません。データ使い放題の有効期間中は送りません(公式アプリの注意書きと同じ)。")
                }
                if !used.isEmpty {
                    Section("使用済み・結果") {
                        ForEach(used) { c in
                            CodeRow(code: c)
                                .swipeActions {
                                    Button(role: .destructive) { Task { await store.removeCode(c.id) } } label: { Label("削除", systemImage: "trash") }
                                    if c.status != .applied {
                                        Button { Task { await store.resetCode(c.id) } } label: { Label("未使用に戻す", systemImage: "arrow.uturn.backward") }.tint(.orange)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("コード")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAdd = true } label: { Label("まとめて登録", systemImage: "text.badge.plus") }
                        Button { showManual = true } label: { Label("1件だけ今すぐ使う", systemImage: "paperplane") }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .accessibilityIdentifier("codes.add")
                }
            }
            .sheet(isPresented: $showAdd) { AddCodesSheet() }
            .sheet(isPresented: $showManual) { ManualCodeSheet() }
            .sheet(item: $editTarget) { c in EditCodeSheet(code: c) }
            .alert("このコードを今使いますか?", isPresented: Binding(get: { applyTarget != nil }, set: { if !$0 { applyTarget = nil } })) {
                TextField("「利用する」と入力", text: $confirmText)
                Button("送信") {
                    if let c = applyTarget {
                        let word = confirmText
                        Task { await store.applyCode(id: c.id, confirm: word) }
                    }
                    confirmText = ""
                    applyTarget = nil
                }
                Button("やめる", role: .cancel) {
                    confirmText = ""
                    applyTarget = nil
                }
            } message: {
                Text("\(applyTarget?.masked ?? "")を povo に送ります。コードは1回しか使えないものがほとんどです。")
            }
            .refreshable { await store.reload() }
        }
    }
}

struct CodeRow: View {
    let code: CodeEntry
    @State private var reveal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(reveal ? code.code : code.masked)
                    .font(.body.monospaced())
                    .onTapGesture { reveal.toggle() }
                if !code.tag.isEmpty {
                    Text(code.tag)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.yellow, in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer()
                Text(statusLabel).font(.caption.weight(.semibold)).foregroundStyle(statusColor)
            }
            if !code.note.isEmpty { Text(code.note).font(.caption).foregroundStyle(.secondary) }
            if let r = code.result { Text(r).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }

    private var statusLabel: String {
        switch code.status {
        case .pending: return "未使用"
        case .sent: return "結果不明"
        case .applied: return "適用済み"
        case .rejected: return "受付不可"
        case .error: return "エラー"
        }
    }

    private var statusColor: Color {
        switch code.status {
        case .pending: return .secondary
        case .applied: return Theme.ok
        case .rejected, .error: return Theme.danger
        case .sent: return Theme.warn
        }
    }
}

struct AddCodesSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: AddCodesResult?
    @State private var showScanner = false

    private var canScan: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 160)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("codes.text")
                    if canScan {
                        Button { showScanner = true } label: { Label("カメラで読み取る", systemImage: "camera.viewfinder") }
                    }
                } header: {
                    Text("1行に1件: コード タグ メモ")
                } footer: {
                    Text("例:\nABCD1234EFGH 1gb 7日間\nWXYZ5678 24h 使い放題\nタグはルールで applyCode(\"1gb\") のように選ぶのに使います(省略可)。")
                }
                if let r = result {
                    Section {
                        Label("\(r.added)件を登録しました", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ok)
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
                            let r = await store.addCodes(text)
                            result = r
                            if r.invalid.isEmpty && r.added > 0 {
                                store.toast = "\(r.added)件を登録しました"
                                dismiss()
                            }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("codes.save")
                }
            }
            .sheet(isPresented: $showScanner) {
                CodeScannerSheet { found in
                    let lines = found.filter { !text.contains($0) }
                    if !lines.isEmpty {
                        text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n")
                    }
                }
            }
        }
    }
}

struct ManualCodeSheet: View {
    @EnvironmentObject var store: AppStore
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
                    Text("公式アプリと同じく、大文字にして前後の空白を除き、18文字以内で送ります。データ使い放題の有効期間中は送れません。")
                }
                Section {
                    Button {
                        let c = code, w = confirm
                        Task {
                            await store.applyCode(raw: c, confirm: w)
                            dismiss()
                        }
                    } label: {
                        Text("送信")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .disabled(code.isEmpty || confirm != "利用する" || store.isBusy("code"))
                }
            }
            .navigationTitle("コードを今すぐ使う")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

struct EditCodeSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let code: CodeEntry
    @State private var tag = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(code.masked) {
                    TextField("タグ(例: 1gb, 24h)", text: $tag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("メモ", text: $note)
                }
            }
            .navigationTitle("コードを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let t = tag, n = note
                        Task {
                            await store.updateCode(code.id, tag: t, note: n)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                tag = code.tag
                note = code.note
            }
        }
    }
}

/// プリペイドカードなどのコードをカメラで読み取る(対応端末のみ)。
struct CodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onDone: ([String]) -> Void
    @State private var found: [String] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CodeScanner(found: $found)
                    .ignoresSafeArea(edges: .bottom)
                if !found.isEmpty {
                    List(found, id: \.self) { Text($0).font(.body.monospaced()) }
                        .frame(maxHeight: 180)
                }
            }
            .navigationTitle("コードを読み取る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加(\(found.count))") {
                        onDone(found)
                        dismiss()
                    }
                    .disabled(found.isEmpty)
                }
            }
        }
    }
}

struct CodeScanner: UIViewControllerRepresentable {
    @Binding var found: [String]

    func makeCoordinator() -> Coordinator { Coordinator(found: $found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.text()], qualityLevel: .accurate,
                                           recognizesMultipleItems: true, isHighFrameRateTrackingEnabled: false,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        @Binding var found: [String]

        init(found: Binding<[String]>) {
            _found = found
        }

        /// 英数字(と - _)だけの 8〜18 文字をコードの候補にする。
        nonisolated static func candidates(in text: String) -> [String] {
            text.uppercased()
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-_")) }
                .filter { $0.count >= 8 && $0.count <= 18 && $0.rangeOfCharacter(from: .decimalDigits) != nil }
                .filter { $0.allSatisfy { $0.isASCII } }
        }

        private func add(_ items: [RecognizedItem]) {
            for item in items {
                if case let .text(t) = item {
                    for c in Coordinator.candidates(in: t.transcript) where !found.contains(c) {
                        found.append(c)
                    }
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            add(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            add([item])
        }
    }
}
