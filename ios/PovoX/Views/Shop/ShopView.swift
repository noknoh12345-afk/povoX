import SwiftUI
import WebKit

/// 購入できるトッピング(手動購入)。ルールの安全装置とは別に、確認語で二重に確かめる。
struct ShopView: View {
    @EnvironmentObject var store: AppStore
    @State private var target: Product?
    @State private var confirmText = ""
    @State private var cheapFirst = false

    private var products: [Product] {
        let list = store.catalog?.products ?? []
        return cheapFirst ? list.sorted { ($0.priceYen ?? .max) < ($1.priceYen ?? .max) } : list
    }

    private var sections: [(String, [Product])] {
        if cheapFirst { return [("安い順", products)] }
        var order: [String] = []
        var map: [String: [Product]] = [:]
        for p in products {
            let s = p.section ?? "その他"
            if map[s] == nil { order.append(s) }
            map[s, default: []].append(p)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        List {
            Section {
                NavigationLink { OptimizeView() } label: {
                    Label("最安の買い方を見る", systemImage: "sparkles")
                }
                .accessibilityIdentifier("shop.optimize")
            } footer: {
                Text("今の減り方から、この先をまかなう一番安い買い方(コード→データ→使い放題)を出します。")
            }
            if store.catalog == nil {
                Section {
                    Button {
                        Task { await store.loadCatalog(force: false) }
                    } label: {
                        Label("購入できるトッピングを読み込む", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("一覧は6時間使い回します(povo への通信を減らすため)。下に引っ張ると読み直します。")
                }
            } else {
                Section {
                    Picker("並び", selection: $cheapFirst) {
                        Text("povo の順").tag(false)
                        Text("安い順").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                ForEach(sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { p in
                            Button { target = p } label: { ProductRow(product: p) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("shop.\(p.sku)")
                        }
                    }
                }
                if let c = store.catalog {
                    Section {
                        Text("一覧の取得: \(Fmt.when(ms: c.fetchedMs))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .textCase(nil)
        .navigationTitle("トッピング")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.loadCatalog(force: true) }
        .overlay { if store.isBusy("catalog") || store.isBusy("order") { ProgressView() } }
        .alert("購入しますか?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            TextField("「購入する」と入力", text: $confirmText)
                .accessibilityIdentifier("shop.confirm")
            Button("購入") {
                if let p = target {
                    let word = confirmText
                    Task { await store.order(p, confirm: word) }
                }
                confirmText = ""
                target = nil
            }
            Button("やめる", role: .cancel) {
                confirmText = ""
                target = nil
            }
        } message: {
            if let p = target {
                Text("\(p.name)\n\(p.priceText ?? "価格不明")\(p.requires3ds ? "\n3Dセキュアの認証画面が開きます" : "")\n同じ商品は2分以内に重ねて注文できません。")
            }
        }
        .task {
            if store.catalog == nil, store.loggedIn { await store.loadCatalog(force: false) }
        }
    }
}

struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(product.unlimited ? Theme.yellow : Theme.groove)
                    .frame(width: 42, height: 42)
                if product.unlimited {
                    Image(systemName: "infinity").font(.headline.weight(.bold)).foregroundStyle(.black)
                } else if let gb = product.dataGb {
                    Text(gb >= 1 ? String(format: "%.0f", gb) : String(format: "%.1f", gb))
                        .font(.headline.weight(.bold)).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(product.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if let v = product.validity { Text(v) }
                    if let y = product.yenPerGb { Text("1GBあたり \(Int(y))円") }
                    if product.requires3ds { Text("3DS").fontWeight(.bold) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(product.priceText ?? "—").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// 3Dセキュアの認証画面。povo-android と同じく `https://povo.jp/success` に来たら完了とみなす。
struct ChallengeView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let page: ChallengePage

    var body: some View {
        NavigationStack {
            ChallengeWebView(url: page.url) {
                store.toast = "\(page.label): 認証が終わりました。購入履歴で確かめてください。"
                Task { await store.refresh(force: true) }
                dismiss()
            }
            .navigationTitle("3Dセキュア")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

struct ChallengeWebView: UIViewRepresentable {
    let url: URL
    let onSuccess: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSuccess: onSuccess) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSuccess: () -> Void
        private var done = false

        init(onSuccess: @escaping () -> Void) {
            self.onSuccess = onSuccess
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let u = navigationAction.request.url, u.host == "povo.jp", u.path.hasPrefix("/success") {
                if !done {
                    done = true
                    onSuccess()
                }
                return .cancel
            }
            return .allow
        }
    }
}
