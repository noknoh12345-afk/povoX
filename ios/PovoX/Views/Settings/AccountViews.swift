import SwiftUI
import UIKit

/// アカウント情報(プロフィール・請求・友だち紹介)。すべて読み取り。
struct ProfileView: View {
    @EnvironmentObject var store: AppStore
    @State private var profile: AccountProfile?
    @State private var loaded = false

    var body: some View {
        Form {
            if let p = profile {
                Section("契約") {
                    row("プラン", p.plan)
                    row("状態", p.status)
                    row("電話番号", p.phone)
                    row("開通日", p.activationDate)
                }
                Section("お客さま") {
                    row("お名前", p.firstName)
                    row("メール", p.email)
                }
            } else if store.isBusy("profile") {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else {
                Section { Text("読み込めませんでした。") .foregroundStyle(.secondary) }
            }
        }
        .textCase(nil)
        .navigationTitle("プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            profile = await store.loadProfile()
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String?) -> some View {
        if let v = value, !v.isEmpty {
            LabeledContent(label, value: v)
        }
    }
}

struct BillsView: View {
    @EnvironmentObject var store: AppStore
    @State private var bills: Bills?
    @State private var loaded = false
    @State private var share: ShareFile?

    var body: some View {
        Form {
            if let b = bills {
                if let total = b.upcomingTotal, !total.isEmpty {
                    Section("今月の予定") { LabeledContent("合計", value: total) }
                }
                Section("請求") {
                    if b.entries.isEmpty {
                        Text("請求はありません。").foregroundStyle(.secondary)
                    }
                    ForEach(Array(b.entries.enumerated()), id: \.offset) { _, e in
                        BillRow(entry: e, onPDF: { Task { await openPDF(e) } }, busy: store.isBusy("billpdf"))
                    }
                }
            } else if store.isBusy("bills") {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else {
                Section { Text("読み込めませんでした。").foregroundStyle(.secondary) }
            }
        }
        .textCase(nil)
        .navigationTitle("請求")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            bills = await store.loadBills()
        }
        .sheet(item: $share) { f in ShareSheet(items: [f.url]) }
    }

    private func openPDF(_ e: BillEntry) async {
        guard let id = e.billId, let data = await store.billPDF(id) else {
            store.toast = "PDF を取得できませんでした"
            return
        }
        let name = (e.title ?? "povo-bill").replacingOccurrences(of: "/", with: "-") + ".pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            share = ShareFile(url: url)
        } catch {
            store.toast = "PDF を保存できませんでした"
        }
    }
}

private struct BillRow: View {
    let entry: BillEntry
    let onPDF: () -> Void
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.title ?? "—").fontWeight(.medium)
                Spacer()
                Text(entry.amount ?? "").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let k = kindLabel { Text(k).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(kindColor.opacity(0.15), in: Capsule()).foregroundStyle(kindColor) }
                if let s = entry.subtitle, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if entry.billId != nil {
                    Button {
                        onPDF()
                    } label: {
                        if busy { ProgressView() } else { Label("PDF", systemImage: "doc") }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var kindLabel: String? {
        switch entry.kind {
        case "paid": return "支払済"
        case "unpaid": return "未払い"
        case "upcoming": return "予定"
        case "instant": return "都度"
        default: return nil
        }
    }
    private var kindColor: Color {
        switch entry.kind {
        case "unpaid": return Theme.danger
        case "upcoming": return .orange
        default: return .secondary
        }
    }
}

struct ReferralView: View {
    @EnvironmentObject var store: AppStore
    @State private var referral: Referral?
    @State private var loaded = false

    var body: some View {
        Form {
            if let r = referral {
                if let code = r.code, !code.isEmpty {
                    Section("あなたの紹介コード") {
                        HStack {
                            Text(code).font(.title3.weight(.bold).monospaced())
                            Spacer()
                            Button {
                                UIPasteboard.general.string = code
                                store.toast = "コピーしました"
                            } label: { Image(systemName: "doc.on.doc") }
                        }
                        ShareLink(item: shareText(code)) { Label("友だちに送る", systemImage: "square.and.arrow.up") }
                    }
                }
                if let m = r.message, !m.isEmpty {
                    Section { Text(m).font(.callout).foregroundStyle(.secondary) }
                }
            } else if store.isBusy("referral") {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else {
                Section { Text("読み込めませんでした。").foregroundStyle(.secondary) }
            }
        }
        .textCase(nil)
        .navigationTitle("友だち紹介")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            loaded = true
            referral = await store.loadReferral()
        }
    }

    private func shareText(_ code: String) -> String {
        "povo2.0 を使っています。紹介コード \(code) で登録すると特典がもらえます。https://povo.jp/"
    }
}

/// 共有シート(PDF の保存・共有)。
private struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
