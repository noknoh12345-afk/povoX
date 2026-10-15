import SwiftUI
import WebKit

struct ShopView: View {
    @EnvironmentObject var model: AppModel
    @State private var target: Product?
    @State private var confirmText = ""
    @State private var sort = 0

    private var products: [Product] {
        let list = model.catalog?.products ?? []
        switch sort {
        case 1: return list.sorted { ($0.priceYen ?? .max) < ($1.priceYen ?? .max) }
        default: return list
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.catalog == nil {
                    Section {
                        Button {
                            Task { await model.loadCatalog(force: false) }
                        } label: {
                            Label("購入できるトッピングを読み込む", systemImage: "arrow.down.circle")
                        }
                    } footer: {
                        Text("一覧は6時間ごとに読み直します(povo への通信を減らすため)。")
                    }
                } else {
                    Section {
                        Picker("並び", selection: $sort) {
                            Text("povo の順").tag(0)
                            Text("安い順").tag(1)
                        }
                        .pickerStyle(.segmented)
                    }
                    let sections = Dictionary(grouping: products, by: { $0.section ?? "その他" })
                    let order = products.map { $0.section ?? "その他" }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                    ForEach(sort == 1 ? ["安い順"] : order, id: \.self) { title in
                        Section(title) {
                            ForEach(sort == 1 ? products : (sections[title] ?? [])) { p in
                                ProductRow(product: p)
                                    .contentShape(Rectangle())
                                    .onTapGesture { target = p }
                            }
                        }
                    }
                    if let c = model.catalog {
                        Section {
                            Text("一覧の取得: \(Date(timeIntervalSince1970: Double(c.fetchedMs) / 1000).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("トッピング")
            .refreshable { await model.loadCatalog(force: true) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.busy { ProgressView() }
                }
            }
            .alert("購入しますか?", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                TextField("「購入する」と入力", text: $confirmText)
                Button("購入") {
                    if let p = target {
                        let word = confirmText
                        Task { await model.order(p, confirm: word) }
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
                    Text("\(p.name)\n\(p.price ?? "価格不明")\(p.requires3ds ? "\n3Dセキュアの認証画面が開きます" : "")\n同じ商品は2分以内に重ねて注文できません。")
                }
            }
            .task {
                if model.catalog == nil, model.status?.loggedIn == true {
                    await model.loadCatalog(force: false)
                }
            }
        }
    }
}

struct ProductRow: View {
    let product: Product

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(product.name).font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    if let v = product.validity { Text(v) }
                    if product.requires3ds { Text("3DS").bold() }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(product.sku).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(product.price ?? "—").font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 2)
    }
}

/// 3-D セキュアの認証画面。povo-android と同じく、`https://povo.jp/success` に来たら完了とみなす。
struct ChallengeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let page: ChallengePage

    var body: some View {
        NavigationStack {
            ChallengeWebView(url: page.url) {
                model.toast = "\(page.productName): 3Dセキュアの認証が終わりました。購入履歴で確かめてください。"
                Task { await model.refresh(force: true) }
                dismiss()
            }
            .navigationTitle("3Dセキュア")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
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
